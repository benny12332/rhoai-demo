#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - GPU 設定自動化
# 對應手冊「3. 設定 GPU Operator」:
#   1. 建立 NFD instance (預設值)
#   2. 建立 GPU Operator ClusterPolicy (預設值)
#   3. 驗證 GPU Driver 正常運作 (nvidia-smi)
#
# 「預設值」直接從各 Operator CSV 的 alm-examples 取得,
# 跟 GUI 按 Create 用預設值的效果完全相同, 不會因版本改變而過期
# =============================================================
set -euo pipefail

NFD_NS="openshift-nfd"
GPU_NS="nvidia-gpu-operator"

wait_csv() { # wait_csv <namespace> <csv名稱關鍵字>
  local ns="$1" key="$2"
  echo ">>> 等待 $key CSV Succeeded (ns=$ns)"
  for i in $(seq 1 60); do
    csv=$(oc get csv -n "$ns" -o name 2>/dev/null | grep "$key" | head -1 || true)
    if [ -n "$csv" ]; then
      phase=$(oc get "$csv" -n "$ns" -o jsonpath='{.status.phase}')
      [ "$phase" = "Succeeded" ] && echo "    $csv Succeeded" && return 0
    fi
    sleep 10
  done
  echo "!!! 等不到 $key CSV Succeeded"; exit 1
}

create_from_alm() { # create_from_alm <namespace> <csv關鍵字> <kind>
  local ns="$1" key="$2" kind="$3"
  local csv
  csv=$(oc get csv -n "$ns" -o name | grep "$key" | head -1)
  oc get "$csv" -n "$ns" -o jsonpath='{.metadata.annotations.alm-examples}' \
    | jq --arg k "$kind" '[.[] | select(.kind == $k)][0]' \
    | oc apply -n "$ns" -f -
}

# ---------- 1. NFD instance ----------
wait_csv "$NFD_NS" "nfd"
if oc get nodefeaturediscovery -n "$NFD_NS" --no-headers 2>/dev/null | grep -q .; then
  echo ">>> NodeFeatureDiscovery 已存在，跳過"
else
  echo ">>> 建立 NodeFeatureDiscovery (預設值)"
  create_from_alm "$NFD_NS" "nfd" "NodeFeatureDiscovery"
fi

# 等 NFD 給 GPU 節點打上 PCI 標籤 (10de = NVIDIA vendor id)
echo ">>> 等待 NFD 偵測到 NVIDIA GPU 節點"
for i in $(seq 1 30); do
  n=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "    偵測到 $n 個 GPU 節點" && break
  sleep 10
  [ "$i" -eq 30 ] && { echo "!!! NFD 未偵測到 GPU 節點，確認 GPU MachineSet 是否已就緒"; exit 1; }
done

# ---------- 2. ClusterPolicy ----------
wait_csv "$GPU_NS" "gpu-operator"
if oc get clusterpolicy gpu-cluster-policy >/dev/null 2>&1; then
  echo ">>> ClusterPolicy 已存在，跳過"
else
  echo ">>> 建立 ClusterPolicy (預設值)"
  create_from_alm "$GPU_NS" "gpu-operator" "ClusterPolicy"
fi

# ---------- 3. 驗證 ----------
echo ">>> 等待 ClusterPolicy state=ready (driver 編譯安裝約需 10-20 分鐘)"
for i in $(seq 1 120); do
  state=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || true)
  [ "$state" = "ready" ] && echo "    ClusterPolicy ready" && break
  sleep 15
  [ "$i" -eq 120 ] && { echo "!!! ClusterPolicy 未 ready，檢查: oc get pods -n $GPU_NS"; exit 1; }
done

echo ">>> 在 driver pod 內執行 nvidia-smi 驗證"
pod=$(oc get pods -n "$GPU_NS" -o name | grep nvidia-driver-daemonset | head -1)
oc exec -n "$GPU_NS" "${pod}" -c nvidia-driver-ctr -- nvidia-smi

echo ""
echo ">>> 節點可分配的 GPU 數量:"
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

echo ">>> GPU 設定完成"
