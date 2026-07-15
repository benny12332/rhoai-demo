#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 00. 環境準備
#   0. 清除上一個環境的暫存檔
#   1. 引導輸入 OCP API 與 admin 帳密並登入
#   2. 一般 worker MachineSet: 已存在 -> replicas=1
#   3. GPU MachineSet (g6e.12xlarge, 4x L40S):
#      - 監控 Machine 狀態, 遇 InsufficientInstanceCapacity
#        (該 AZ 無 GPU 資源) 自動刪除 MachineSet 並引導換 AZ 重試
#      - 換 AZ 前檢查該區 subnet 是否存在; 不存在則用叢集的
#        aws-cloud-credentials Secret 透過 aws CLI 建立 subnet
# 需要: oc, jq; aws CLI (選用, 僅在需要建立 subnet 時)
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
echo "=== 0.1 OCP 登入 ==="
CRED_FILE="${REPO_DIR}/00_prepare/.ocp_credentials"

USE_SAVED=""
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  echo ">>> 偵測到已儲存的 credential:"
  echo "    API : ${OCP_API}"
  echo "    帳號: ${OCP_USER}"
  read -r -p "是否使用? [Y/n]: " ans
  if [ "${ans:-Y}" = "n" ] || [ "${ans:-Y}" = "N" ]; then
    USE_SAVED="no"
  else
    USE_SAVED="yes"
  fi
fi

if [ "$USE_SAVED" != "yes" ]; then
  read -r -p "API URL (例 https://api.cluster.example.com:6443): " OCP_API
  read -r -p "帳號 [admin]: " OCP_USER
  OCP_USER="${OCP_USER:-admin}"
  read -r -s -p "密碼: " OCP_PASS; echo
fi

if ! oc login "$OCP_API" -u "$OCP_USER" -p "$OCP_PASS" --insecure-skip-tls-verify=true >/dev/null; then
  # 已存的 credential 失效 (叢集換了/密碼改了) -> 移除並要求重新輸入
  echo "!!! 登入失敗"
  if [ "$USE_SAVED" = "yes" ]; then
    echo ">>> 已儲存的 credential 無效，移除 ${CRED_FILE#$REPO_DIR/}，請重跑 prepare.sh 重新輸入"
    rm -f "$CRED_FILE"
  fi
  exit 1
fi
echo ">>> 登入成功: $(oc whoami) @ $(oc whoami --show-server)"

# 登入成功後儲存 credential 供下次使用 (僅本機, 已加入 .gitignore, 權限 600)
if [ "$USE_SAVED" != "yes" ]; then
  cat > "$CRED_FILE" <<EOF
OCP_API='${OCP_API}'
OCP_USER='${OCP_USER}'
OCP_PASS='${OCP_PASS}'
EOF
  chmod 600 "$CRED_FILE"
  echo ">>> credential 已儲存至 ${CRED_FILE#$REPO_DIR/} (下次重跑會詢問是否沿用)"
fi

INFRA=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
echo ">>> Cluster: ${INFRA} (region: ${REGION})"
echo ">>> 現行 MachineSet:"
oc get machineset -n $MAPI_NS

# ---------- 2. 一般 worker MachineSet ----------
echo ""
echo "=== 0.2 一般 Worker ==="
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

# ---------- AWS 工具 (subnet 檢查/建立用) ----------
AWS_READY=0
setup_aws_cli() {
  [ "$AWS_READY" = "1" ] && return 0
  command -v aws >/dev/null 2>&1 || { echo "    (未安裝 aws CLI，無法檢查/建立 subnet)"; return 1; }
  AWS_ACCESS_KEY_ID=$(oc get secret aws-cloud-credentials -n $MAPI_NS -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
  AWS_SECRET_ACCESS_KEY=$(oc get secret aws-cloud-credentials -n $MAPI_NS -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$REGION"
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "    (aws-cloud-credentials 無法通過驗證)"; return 1; }
  AWS_READY=1
}

subnet_name_for_az() { # 由模板 subnet 名稱換 AZ
  local az="$1"
  oc get machineset "$WORKER_MS" -n $MAPI_NS \
    -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.filters[0].values[0]}' \
    | sed -E "s/[a-z]{2}-[a-z]+-[0-9][a-z]$/${az}/"
}

subnet_exists() { # subnet_exists <az>; 回傳 0 存在
  local name; name=$(subnet_name_for_az "$1")
  setup_aws_cli || return 0   # 沒有 aws CLI 時不擋流程 (由 Machine 錯誤把關)
  local sid
  sid=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${name}" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
  [ -n "$sid" ] && [ "$sid" != "None" ]
}

create_subnet() { # create_subnet <az>
  local az="$1" name; name=$(subnet_name_for_az "$az")
  setup_aws_cli || { echo "!!! 需要 aws CLI 與有效的 aws-cloud-credentials 才能建立 subnet"; return 1; }
  echo ">>> 在 ${az} 建立 subnet: ${name}"

  # 以模板 worker 的 subnet 為參考: 取 VPC 與 route table
  local ref_name ref_id vpc rtb
  ref_name=$(oc get machineset "$WORKER_MS" -n $MAPI_NS \
    -o jsonpath='{.spec.template.spec.providerSpec.value.subnet.filters[0].values[0]}')
  ref_id=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${ref_name}" \
    --query 'Subnets[0].SubnetId' --output text)
  [ "$ref_id" = "None" ] && { echo "!!! 找不到參考 subnet ${ref_name}"; return 1; }
  vpc=$(aws ec2 describe-subnets --subnet-ids "$ref_id" --query 'Subnets[0].VpcId' --output text)
  rtb=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${ref_id}" \
    --query 'RouteTables[0].RouteTableId' --output text)

  # 從 VPC CIDR 找一個未使用的 /24
  local vpc_cidr base new_id="" third
  vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].CidrBlock' --output text)
  base=$(echo "$vpc_cidr" | cut -d. -f1-2)
  for third in $(seq 200 250); do
    new_id=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "${base}.${third}.0/24" \
      --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=kubernetes.io/cluster/${INFRA},Value=owned},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
      --query 'Subnet.SubnetId' --output text 2>/dev/null) && break
    new_id=""
  done
  [ -z "$new_id" ] && { echo "!!! 找不到可用的 CIDR 建立 subnet"; return 1; }

  # 綁定參考 subnet 的 route table (走同一個 NAT, 跨 AZ 流量在 demo 可接受)
  aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$new_id" >/dev/null
  echo ">>> Subnet 已建立: ${new_id} (${base}.${third}.0/24) 並綁定 ${rtb}"
}

ensure_subnet() { # ensure_subnet <az>
  if subnet_exists "$1"; then
    echo ">>> ${1} 的 subnet 存在"
  else
    echo ">>> ${1} 的 subnet 不存在"
    create_subnet "$1" || return 1
  fi
}

# ---------- GPU MachineSet 建立與監控 ----------
create_gpu_ms() { # create_gpu_ms <name> <az>
  local name="$1" az="$2"
  oc get machineset "$WORKER_MS" -n $MAPI_NS -o json | jq \
    --arg name "$name" --arg az "$az" --arg itype "$GPU_INSTANCE_TYPE" '
    del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
        .metadata.generation, .metadata.annotations, .metadata.managedFields, .status)
    | .metadata.name = $name
    | .spec.replicas = 1
    | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.spec.metadata.labels = {
        "node-role.kubernetes.io/gpu": "",
        "nvidia.com/gpu.present": "true"
      }
    | .spec.template.spec.taints = [
        {"key": "nvidia.com/gpu", "value": "true", "effect": "NoSchedule"}
      ]
    | .spec.template.spec.providerSpec.value.instanceType = $itype
    | .spec.template.spec.providerSpec.value.placement.availabilityZone = $az
    | .spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeSize = 200
    | (.spec.template.spec.providerSpec.value.subnet.filters[0].values[0])
        |= sub("[a-z]{2}-[a-z]+-[0-9][a-z]$"; $az)
  ' | oc apply -f -
}

# 監控 GPU Machine: 回傳 0=Running, 2=容量不足(確認5分鐘無變化), 1=其他錯誤/逾時
watch_gpu_machine() { # watch_gpu_machine <machineset名>
  local ms="$1" i phase errmsg cap_since=0 now
  echo ">>> 監控 Machine 狀態 (machineset=${ms})"
  for i in $(seq 1 80); do   # 最多 20 分鐘
    phase=$(oc get machine -n $MAPI_NS \
      -l "machine.openshift.io/cluster-api-machineset=${ms}" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    errmsg=$(oc get machine -n $MAPI_NS \
      -l "machine.openshift.io/cluster-api-machineset=${ms}" \
      -o jsonpath='{.items[0].status.errorMessage}' 2>/dev/null || true)

    # Running 優先判斷 (容量不足後 machine-api 重試成功會直接變 Running)
    if [ "$phase" = "Running" ]; then
      echo ">>> GPU Machine Running"; return 0
    fi

    if echo "$errmsg" | grep -q "InsufficientInstanceCapacity"; then
      now=$(date +%s)
      if [ "$cap_since" -eq 0 ]; then
        cap_since=$now
        echo "!!! 偵測到 InsufficientInstanceCapacity (該 AZ 暫無 ${GPU_INSTANCE_TYPE} 資源)"
        echo "    再觀察 5 分鐘確認是否只是暫時性缺貨..."
      elif [ $((now - cap_since)) -ge 300 ]; then
        echo "!!! 容量不足已持續 5 分鐘無變化，確認該 AZ 沒有資源"
        return 2
      else
        echo "    ... 容量不足持續 $(( (now - cap_since) ))s / 300s"
      fi
    else
      # 錯誤消失 (machine-api 重試中) -> 重置計時
      if [ "$cap_since" -ne 0 ]; then
        echo "    容量錯誤已消失，machine-api 重試中，重置觀察計時"
        cap_since=0
      fi
      if [ "$phase" = "Failed" ]; then
        echo "!!! Machine Failed: ${errmsg:-未知原因}"; return 1
      fi
      [ $((i % 4)) -eq 0 ] && echo "    ... 等待中 ($((i*15))s) 目前: ${phase:-建立中}"
    fi
    sleep 15
  done
  echo "!!! 逾時: Machine 未進入 Running"
  oc get machine -n $MAPI_NS -l "machine.openshift.io/cluster-api-machineset=${ms}"
  return 1
}

echo ""
echo "=== 0.3 GPU Worker (${GPU_INSTANCE_TYPE}) ==="
GPU_MS=$(oc get machineset -n $MAPI_NS -o name | sed 's|.*/||' | grep gpu | head -1 || true)

if [ -n "$GPU_MS" ]; then
  # 已存在: 確保 replicas>=1 後直接進監控
  CUR=$(oc get machineset "$GPU_MS" -n $MAPI_NS -o jsonpath='{.spec.replicas}')
  [ "$CUR" -lt 1 ] && oc scale machineset "$GPU_MS" -n $MAPI_NS --replicas=1
  GPU_AZ=$(oc get machineset "$GPU_MS" -n $MAPI_NS \
    -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
else
  TPL_AZ=$(oc get machineset "$WORKER_MS" -n $MAPI_NS \
    -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
  read -r -p "GPU 節點的 AZ [${TPL_AZ}]: " GPU_AZ
  GPU_AZ="${GPU_AZ:-$TPL_AZ}"
  ensure_subnet "$GPU_AZ" || exit 1
  GPU_MS="${INFRA}-gpu-l40s-${GPU_AZ}"
  echo ">>> 以 ${WORKER_MS} 為模板建立 ${GPU_MS}"
  create_gpu_ms "$GPU_MS" "$GPU_AZ"
fi

# 容量不足 -> 刪 MachineSet -> 換 AZ (確認/建立 subnet) -> 重建, 直到成功
while true; do
  watch_gpu_machine "$GPU_MS" && break
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo ">>> 刪除 MachineSet ${GPU_MS} 並更換 AZ"
    oc delete machineset "$GPU_MS" -n $MAPI_NS
    echo ">>> Region ${REGION} 可用的 AZ:"
    if setup_aws_cli; then
      aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | sed 's/^/    /'
    else
      echo "    (無 aws CLI，請自行確認，例如 ${REGION}a/${REGION}b/${REGION}c)"
    fi
    read -r -p "輸入新的 AZ (目前失敗: ${GPU_AZ}): " GPU_AZ
    [ -z "$GPU_AZ" ] && { echo "!!! 未輸入 AZ"; exit 1; }
    ensure_subnet "$GPU_AZ" || exit 1
    GPU_MS="${INFRA}-gpu-l40s-${GPU_AZ}"
    echo ">>> 重建 ${GPU_MS}"
    create_gpu_ms "$GPU_MS" "$GPU_AZ"
  else
    echo "!!! 請依上方訊息排除後重跑 prepare.sh"; exit 1
  fi
done

# ---------- 4. 等待節點就緒 ----------
echo ""
echo ">>> 0.4 等待所有 Machines Running / 節點 Ready"
for i in $(seq 1 40); do
  NOT_READY=$(oc get machines -n $MAPI_NS --no-headers | awk '$2!="Running" && $2!="" {c++} END{print c+0}')
  [ "$NOT_READY" -eq 0 ] && echo ">>> 全部 Machines Running" && break
  sleep 15
  [ "$i" -eq 40 ] && { echo "!!! 仍有 Machine 未 Running:"; oc get machines -n $MAPI_NS; exit 1; }
done

echo ""
echo ">>> 節點狀態:"
oc get nodes
echo ">>> 環境準備完成，接著執行 01_install_operator/install.sh"
