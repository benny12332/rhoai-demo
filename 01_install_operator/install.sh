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

# 格式: 顯示名稱|套件名|安裝ns|channel(空=default)|catalog|og模式|csv關鍵字|鎖定版本CSV(空=最新)
#   og模式: own=OwnNamespace, all=AllNamespaces, none=openshift-operators(免OG)
#   鎖定版本: 填 startingCSV (如 rhcl-operator.v1.3.4), OLM 會停在該版不自動升級
OPERATORS=(
  "cert-manager Operator|openshift-cert-manager-operator|cert-manager-operator|stable-v1|redhat-operators|own|cert-manager|"
  "Node Feature Discovery|nfd|openshift-nfd|stable|redhat-operators|own|nfd|"
  "NVIDIA GPU Operator|gpu-operator-certified|nvidia-gpu-operator||certified-operators|own|gpu-operator|"
  "Red Hat Connectivity Link|rhcl-operator|rhcl-operator||redhat-operators|all|rhcl-operator.v1.3.4|rhcl-operator.v1.3.4"
  "Leader Worker Set|leader-worker-set|openshift-lws-operator||redhat-operators|own|leader-worker-set|"
  "Red Hat build of Kueue|kueue-operator|openshift-kueue-operator||redhat-operators|all|kueue|"
  "Job Set Operator|job-set|openshift-jobset-operator|stable-v1.0|redhat-operators|own|jobset|"
  "Custom Metrics Autoscaler|openshift-custom-metrics-autoscaler-operator|openshift-keda|stable|redhat-operators|all|custom-metrics-autoscaler|"
  # 注意: Service Mesh 3 不要自行安裝!
  # RHOAI 3.4 的 rhods-operator 會在建立 DSC 時自動安裝它驗證過的 SM3 版本;
  # 自行預裝會造成 "intersecting operatorgroups provide the same apis" 衝突,
  # 且 RHOAI 指定的 Istio 版本會被較新的 SM3 webhook 以 EOL 拒絕 -> GatewayClass 卡死
  "Red Hat OpenShift AI|rhods-operator|redhat-ods-operator|stable-3.4|redhat-operators|all|rhods-operator.3|"
  "Cluster Observability|cluster-observability-operator|openshift-cluster-observability-operator|stable|redhat-operators|all|cluster-observability|"
  "Tempo Operator|tempo-product|openshift-tempo-operator|stable|redhat-operators|all|tempo|"
  "OpenTelemetry|opentelemetry-product|openshift-opentelemetry-operator|stable|redhat-operators|all|opentelemetry|"
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

approve_installplan() { # approve_installplan <ns> <套件名>
  # 所有 Subscription 都是 Manual approval (禁止自動升級),
  # 首次安裝的 InstallPlan 由此函式核准
  local ns="$1" pkg="$2" i ip approved
  echo "    等待 InstallPlan 出現並核准"
  for i in $(seq 1 30); do
    ip=$(oc get subscription "$pkg" -n "$ns" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
    if [ -n "$ip" ]; then
      approved=$(oc get installplan "$ip" -n "$ns" -o jsonpath='{.spec.approved}' 2>/dev/null || true)
      if [ "$approved" = "false" ]; then
        oc patch installplan "$ip" -n "$ns" --type merge -p '{"spec":{"approved":true}}' >/dev/null
        echo "    InstallPlan ${ip} 已核准"
      fi
      return 0
    fi
    sleep 10
  done
  echo "!!! 等不到 ${pkg} 的 InstallPlan"; return 1
}

install_one() {
  local display="$1" pkg="$2" ns="$3" channel="$4" src="$5" og="$6" csvkey="$7" pincsv="$8"

  # 已裝好 -> 跳過
  if csv_ok "$ns" "$csvkey"; then
    echo ">>> [跳過] ${display} 已 Succeeded"
    return 0
  fi

  echo ">>> 安裝 ${display} (${pkg} @ ${ns})${pincsv:+ [鎖定 ${pincsv}]}"
  [ "$og" != "none" ] && ensure_ns "$ns" && ensure_og "$ns" "$og"

  # Subscription (channel 為空則用套件 default channel)
  # 全部 Manual approval: 首次安裝由腳本核准, 之後的升級 InstallPlan
  # 會停在待核准狀態 => 不會自動升級
  {
    echo "apiVersion: operators.coreos.com/v1alpha1"
    echo "kind: Subscription"
    echo "metadata: {name: ${pkg}, namespace: ${ns}}"
    echo "spec:"
    echo "  name: ${pkg}"
    [ -n "$channel" ] && echo "  channel: ${channel}"
    echo "  source: ${src}"
    echo "  sourceNamespace: ${MARKET_NS}"
    [ -n "$pincsv" ] && echo "  startingCSV: ${pincsv}"
    echo "  installPlanApproval: Manual"
  } | oc apply -f - >/dev/null
  echo "    Subscription 已建立，等待 CSV Succeeded..."

  approve_installplan "$ns" "$pkg" || exit 1

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
  IFS='|' read -r display pkg ns channel src og csvkey pincsv <<EOF
$entry
EOF
  echo ""
  echo "===== 1.${N} (${N}/${TOTAL}) ${display} ====="
  install_one "$display" "$pkg" "$ns" "$channel" "$src" "$og" "$csvkey" "${pincsv:-}"
done

echo ""
echo ">>> 全部 ${TOTAL} 個 Operator 安裝完成"
oc get csv -A | grep -v Succeeded | grep -v '^NAMESPACE' || echo "(所有 CSV 均為 Succeeded)"
