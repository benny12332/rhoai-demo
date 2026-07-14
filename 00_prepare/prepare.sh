#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 00. 環境準備
#   1. 引導輸入 OCP API 與 admin 帳密並登入
#   2. 一般 worker MachineSet: 已存在 -> replicas=1
#   3. GPU MachineSet (g6e.12xlarge, 4x L40S): 不存在 -> 以現有
#      worker MachineSet 為模板產生; 確保 replicas>=1 (新增一台)
# 需要: oc, jq
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail

MAPI_NS=openshift-machine-api
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g6e.12xlarge}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------- 0. 清除上一個環境的暫存檔 ----------
STALE_FILES=(
  "${REPO_DIR}/.demo_state"
  "${REPO_DIR}/13_maas_subscription/maas-api-key.env"
  "${REPO_DIR}/11_model_registry/registry-ids.env"
)
FOUND=()
for f in "${STALE_FILES[@]}"; do [ -f "$f" ] && FOUND+=("$f"); done
if [ "${#FOUND[@]}" -gt 0 ]; then
  echo "=== 偵測到上一個環境的暫存檔 ==="
  for f in "${FOUND[@]}"; do echo "  - ${f#$REPO_DIR/}"; done
  read -r -p "是否清除? 換新叢集請選 y，同一叢集續跑請選 N [y/N]: " ans
  if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    for f in "${FOUND[@]}"; do rm -f "$f"; done
    echo ">>> 已清除 ${#FOUND[@]} 個暫存檔"
  else
    echo ">>> 保留暫存檔"
  fi
  echo ""
fi

# ---------- 1. 登入 ----------
echo "=== OCP 登入 ==="
read -r -p "API URL (例 https://api.cluster.example.com:6443): " OCP_API
read -r -p "帳號 [admin]: " OCP_USER
OCP_USER="${OCP_USER:-admin}"
read -r -s -p "密碼: " OCP_PASS; echo

oc login "$OCP_API" -u "$OCP_USER" -p "$OCP_PASS" --insecure-skip-tls-verify=true >/dev/null
echo ">>> 登入成功: $(oc whoami) @ $(oc whoami --show-server)"

INFRA=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo ">>> Cluster infra name: ${INFRA}"
echo ">>> 現行 MachineSet:"
oc get machineset -n $MAPI_NS

# ---------- 2. 一般 worker MachineSet ----------
echo ""
echo "=== 一般 Worker ==="
WORKER_MS=$(oc get machineset -n $MAPI_NS -o name | sed 's|.*/||' | grep -v gpu | head -1 || true)
if [ -z "$WORKER_MS" ]; then
  echo "!!! 找不到任何非 GPU 的 MachineSet，無法作為模板"; exit 1
fi
CUR=$(oc get machineset "$WORKER_MS" -n $MAPI_NS -o jsonpath='{.spec.replicas}')
if [ "$CUR" -lt 1 ]; then
  echo ">>> ${WORKER_MS} replicas ${CUR} -> 1"
  oc scale machineset "$WORKER_MS" -n $MAPI_NS --replicas=1
else
  echo ">>> ${WORKER_MS} replicas=${CUR}，維持不動"
fi

# ---------- 3. GPU MachineSet ----------
echo ""
echo "=== GPU Worker (${GPU_INSTANCE_TYPE}) ==="
GPU_MS=$(oc get machineset -n $MAPI_NS -o name | sed 's|.*/||' | grep gpu | head -1 || true)

if [ -z "$GPU_MS" ]; then
  # 以一般 worker 為模板產生 GPU MachineSet
  TPL_AZ=$(oc get machineset "$WORKER_MS" -n $MAPI_NS \
           -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
  read -r -p "GPU 節點的 AZ [${TPL_AZ}]: " GPU_AZ
  GPU_AZ="${GPU_AZ:-$TPL_AZ}"
  GPU_MS="${INFRA}-gpu-l40s-${GPU_AZ}"
  echo ">>> 以 ${WORKER_MS} 為模板建立 ${GPU_MS}"

  oc get machineset "$WORKER_MS" -n $MAPI_NS -o json | jq \
    --arg name  "$GPU_MS" \
    --arg az    "$GPU_AZ" \
    --arg itype "$GPU_INSTANCE_TYPE" '
    del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
        .metadata.generation, .metadata.annotations, .metadata.managedFields, .status)
    | .metadata.name = $name
    | .spec.replicas = 1
    | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    # GPU 節點標籤
    | .spec.template.spec.metadata.labels = {
        "node-role.kubernetes.io/gpu": "",
        "nvidia.com/gpu.present": "true"
      }
    # taint: 避免一般 workload 排上昂貴的 GPU 機器
    | .spec.template.spec.taints = [
        {"key": "nvidia.com/gpu", "value": "true", "effect": "NoSchedule"}
      ]
    | .spec.template.spec.providerSpec.value.instanceType = $itype
    | .spec.template.spec.providerSpec.value.placement.availabilityZone = $az
    # GPU/AI 映像檔較大, root volume 放大到 200GB
    | .spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeSize = 200
    # subnet tag 換成目標 AZ
    | (.spec.template.spec.providerSpec.value.subnet.filters[0].values[0])
        |= sub("[a-z]{2}-[a-z]+-[0-9][a-z]$"; $az)
  ' | oc apply -f -
else
  CUR=$(oc get machineset "$GPU_MS" -n $MAPI_NS -o jsonpath='{.spec.replicas}')
  if [ "$CUR" -lt 1 ]; then
    echo ">>> ${GPU_MS} replicas ${CUR} -> 1"
    oc scale machineset "$GPU_MS" -n $MAPI_NS --replicas=1
  else
    echo ">>> ${GPU_MS} 已存在 replicas=${CUR}，維持不動"
  fi
fi

# ---------- 4. 等待節點就緒 ----------
echo ""
echo ">>> 等待 Machines Running (新機器開機約 5-10 分鐘)"
for i in $(seq 1 60); do
  NOT_READY=$(oc get machines -n $MAPI_NS --no-headers | awk '$2!="Running" && $2!="" {c++} END{print c+0}')
  [ "$NOT_READY" -eq 0 ] && echo ">>> 全部 Machines Running" && break
  sleep 15
  [ "$i" -eq 60 ] && { echo "!!! 仍有 Machine 未 Running:"; oc get machines -n $MAPI_NS; exit 1; }
done

echo ""
echo ">>> 節點狀態:"
oc get nodes
echo ">>> 環境準備完成，接著執行 01_install_operator/install.sh"
