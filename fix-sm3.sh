#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - fix-sm3.sh
# 修復「自行安裝 SM3 與 RHOAI 自管 SM3 衝突」的殘留:
#   1. 移除自行安裝的 SM3 (openshift-servicemesh3-operator 整組)
#   2. 移除 openshift-operators 中 Failed/Pending 的 SM3
#   3. 移除孤兒 sail CRD (v3.4 CRD 擋 RHOAI 的 v3.1 安裝 -> CSV Pending)
#   4. 重啟 rhods-operator 讓它重新自動安裝 SM3
#   5. 等 SM3 Succeeded + GatewayClass Accepted
# 可重複執行
# =============================================================
set -euo pipefail

oc whoami >/dev/null 2>&1 || { echo "!!! 尚未登入 OCP"; exit 1; }

echo "=== 1. 移除自行安裝的 SM3 (若存在) ==="
if oc get ns openshift-servicemesh3-operator >/dev/null 2>&1; then
  oc delete subscription servicemeshoperator3 -n openshift-servicemesh3-operator --ignore-not-found
  oc delete csv -n openshift-servicemesh3-operator \
    $(oc get csv -n openshift-servicemesh3-operator -o name 2>/dev/null | grep servicemesh | sed 's|.*/||') 2>/dev/null || true
  oc delete ns openshift-servicemesh3-operator --wait=false
  echo ">>> 已移除"
else
  echo ">>> 無自行安裝的 SM3"
fi

echo ""
echo "=== 2. 移除 openshift-operators 中卡住的 SM3 ==="
BAD=$(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep servicemesh | grep -Ev 'Succeeded' | awk '{print $1}' || true)
if [ -n "$BAD" ]; then
  # shellcheck disable=SC2086
  oc delete csv -n openshift-operators $BAD
  oc delete subscription servicemeshoperator3 -n openshift-operators --ignore-not-found
  oc delete installplan --all -n openshift-operators
  echo ">>> 已移除: $BAD"
else
  echo ">>> 無卡住的 SM3 CSV"
fi

echo ""
echo "=== 3. 檢查孤兒 sail CRD ==="
# 沒有任何 Succeeded 的 SM3 CSV 時, sail CRD 就是孤兒 (且可能版本過新擋安裝)
if oc get csv -A --no-headers 2>/dev/null | grep servicemesh | grep -q Succeeded; then
  echo ">>> 已有健康的 SM3，保留 CRD"
else
  CRDS=$(oc get crd -o name 2>/dev/null | grep 'sailoperator\.io' | sed 's|.*/||' || true)
  if [ -n "$CRDS" ]; then
    echo ">>> 刪除孤兒 CRD (RHOAI 會連同 Istio CR 一起重建):"
    # shellcheck disable=SC2086
    oc delete crd $CRDS
  else
    echo ">>> 無 sail CRD"
  fi
fi

echo ""
echo "=== 4. 重啟 rhods-operator 觸發重新 reconcile ==="
oc delete pod -n redhat-ods-operator -l name=rhods-operator --ignore-not-found

echo ""
echo "=== 5. 等待 SM3 Succeeded 與 GatewayClass Accepted ==="
for i in $(seq 1 60); do
  ok=$(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep servicemesh | grep -c Succeeded || true)
  [ "$ok" -ge 1 ] && echo ">>> SM3 Succeeded: $(oc get csv -n openshift-operators --no-headers | grep servicemesh | awk '{print $1}')" && break
  [ $((i % 6)) -eq 0 ] && echo "    ... 等待 SM3 ($((i*10))s)"
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! SM3 未恢復: oc get csv,sub,installplan -n openshift-operators | grep -i mesh"; exit 1; }
done
for i in $(seq 1 60); do
  acc=$(oc get gatewayclass data-science-gateway-class -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [ "$acc" = "True" ] && echo ">>> GatewayClass Accepted" && break
  [ $((i % 6)) -eq 0 ] && echo "    ... 等待 GatewayClass ($((i*10))s)"
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! GatewayClass 未 Accepted: oc get istio -A; oc describe gatewayclass data-science-gateway-class"; exit 1; }
done

echo ""
echo ">>> fix-sm3.sh 完成，可回 demo_setup.sh 重跑 06 驗證"
