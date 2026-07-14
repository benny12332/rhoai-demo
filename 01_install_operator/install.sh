#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - Operator 逐一安裝腳本
# 一次裝一個: 建 Namespace/OperatorGroup -> Subscription
#            -> 等該 Operator CSV Succeeded -> 下一個
# OperatorGroup 規則: 該 ns 沒有才建立、已有一個沿用、多個報錯
# 可重複執行 (已 Succeeded 的直接跳過)
# 相容 macOS bash 3.2
# =============================================================
set -euo pipefail

MARKET_NS=openshift-marketplace
CSV_TIMEOUT=60   # 每個 operator 等待次數 (x10s = 10 分鐘)

# 格式: 顯示名稱|套件名|安裝ns|channel(空=default)|catalog|og模式|csv關鍵字
#   og模式: own=OwnNamespace, all=AllNamespaces, none=openshift-operators(免OG)
OPERATORS=(
  "cert-manager Operator|openshift-cert-manager-operator|cert-manager-operator|stable-v1|redhat-operators|own|cert-manager"
  "Node Feature Discovery|nfd|openshift-nfd|stable|redhat-operators|own|nfd"
  "NVIDIA GPU Operator|gpu-operator-certified|nvidia-gpu-operator||certified-operators|own|gpu-operator"
  "Red Hat Connectivity Link|rhcl-operator|openshift-operators||redhat-operators|none|rhcl-operator"
  "Leader Worker Set|leader-worker-set|openshift-lws-operator||redhat-operators|own|leader-worker-set"
  "Red Hat build of Kueue|kueue-operator|openshift-operators||redhat-operators|none|kueue"
  "Job Set Operator|job-set|openshift-jobset-operator|stable-v1.0|redhat-operators|own|jobset"
  "Custom Metrics Autoscaler|openshift-custom-metrics-autoscaler-operator|openshift-keda|stable|redhat-operators|all|custom-metrics-autoscaler"
  "Service Mesh 3|servicemeshoperator3|openshift-operators|stable|redhat-operators|none|servicemeshoperator3"
  "Red Hat OpenShift AI|rhods-operator|redhat-ods-operator|stable-3.4|redhat-operators|all|rhods-operator.3"
  "Cluster Observability|cluster-observability-operator|openshift-operators|stable|redhat-operators|none|cluster-observability"
  "Tempo Operator|tempo-product|openshift-operators|stable|redhat-operators|none|tempo"
  "OpenTelemetry|opentelemetry-product|openshift-operators|stable|redhat-operators|none|opentelemetry"
)

csv_ok() { # csv_ok <ns> <關鍵字>
  oc get csv -n "$1" 2>/dev/null | grep "$2" | grep -q Succeeded
}

ensure_ns() {
  oc get ns "$1" >/dev/null 2>&1 || oc create ns "$1" >/dev/null
}

ensure_og() { # ensure_og <ns> <own|all>
  local ns="$1" mode="$2" count
  count=$(oc get operatorgroup -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    if [ "$mode" = "own" ]; then
      oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: ${ns}-og, namespace: ${ns}}
spec:
  targetNamespaces: [${ns}]
EOF
    else
      oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: ${ns}-og, namespace: ${ns}}
spec: {}
EOF
    fi
    echo "    OperatorGroup 已建立 ($mode)"
  elif [ "$count" -eq 1 ]; then
    echo "    OperatorGroup 已存在，沿用"
  else
    echo "!!! [$ns] 有 $count 個 OperatorGroup，OLM 會失敗，請清到剩一個:"
    oc get operatorgroup -n "$ns"
    exit 1
  fi
}

install_one() {
  local display="$1" pkg="$2" ns="$3" channel="$4" src="$5" og="$6" csvkey="$7"

  # 已裝好 -> 跳過
  if csv_ok "$ns" "$csvkey"; then
    echo ">>> [跳過] ${display} 已 Succeeded"
    return 0
  fi

  echo ">>> 安裝 ${display} (${pkg} @ ${ns})"
  [ "$og" != "none" ] && ensure_ns "$ns" && ensure_og "$ns" "$og"

  # Subscription (channel 為空則用套件 default channel)
  {
    echo "apiVersion: operators.coreos.com/v1alpha1"
    echo "kind: Subscription"
    echo "metadata: {name: ${pkg}, namespace: ${ns}}"
    echo "spec:"
    echo "  name: ${pkg}"
    [ -n "$channel" ] && echo "  channel: ${channel}"
    echo "  source: ${src}"
    echo "  sourceNamespace: ${MARKET_NS}"
    echo "  installPlanApproval: Automatic"
  } | oc apply -f - >/dev/null
  echo "    Subscription 已建立，等待 CSV Succeeded..."

  local i phase
  for i in $(seq 1 "$CSV_TIMEOUT"); do
    if csv_ok "$ns" "$csvkey"; then
      echo "    ✓ ${display} Succeeded ($(oc get csv -n "$ns" 2>/dev/null | grep "$csvkey" | grep Succeeded | awk '{print $1}' | head -1))"
      return 0
    fi
    # 顯示進度 (每 30 秒一次)
    if [ $((i % 3)) -eq 0 ]; then
      phase=$(oc get csv -n "$ns" 2>/dev/null | grep "$csvkey" | awk '{print $NF}' | head -1)
      echo "    ... 等待中 ($((i*10))s) ${phase:+目前狀態: $phase}"
    fi
    sleep 10
  done

  echo "!!! ${display} 在 $((CSV_TIMEOUT*10)) 秒內未 Succeeded，診斷:"
  echo "    oc get subscription ${pkg} -n ${ns} -o jsonpath='{.status.conditions}'"
  echo "    oc get csv,installplan -n ${ns}"
  exit 1
}

# ---------- 主流程 ----------
TOTAL=${#OPERATORS[@]}
N=0
for entry in "${OPERATORS[@]}"; do
  N=$((N+1))
  IFS='|' read -r display pkg ns channel src og csvkey <<EOF
$entry
EOF
  echo ""
  echo "===== [${N}/${TOTAL}] ${display} ====="
  install_one "$display" "$pkg" "$ns" "$channel" "$src" "$og" "$csvkey"
done

echo ""
echo ">>> 全部 ${TOTAL} 個 Operator 安裝完成"
oc get csv -A | grep -v Succeeded | grep -v '^NAMESPACE' || echo "(所有 CSV 均為 Succeeded)"
