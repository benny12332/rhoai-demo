#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - Operator 安裝腳本
# 1. 建立 Namespace + Subscription (install-operators.yaml)
# 2. 每個 namespace「沒有 OperatorGroup 才建立」，
#    已有一個就沿用，發現多個則報錯提示清理
#    (避免 "csv created in namespace with multiple operatorgroups")
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

# namespace|模式  (own = targetNamespaces 自己, all = AllNamespaces)
OG_LIST="
cert-manager-operator|own
openshift-nfd|own
nvidia-gpu-operator|own
openshift-jobset-operator|own
openshift-lws-operator|own
openshift-keda|all
redhat-ods-operator|all
"

echo ">>> Step 1: apply namespaces + subscriptions"
oc apply -f install-operators.yaml

echo ">>> Step 2: ensure exactly one OperatorGroup per namespace"
for entry in $OG_LIST; do
  ns="${entry%%|*}"
  mode="${entry##*|}"
  count=$(oc get operatorgroup -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "$count" -eq 0 ]; then
    echo "  [$ns] 沒有 OperatorGroup，建立 ($mode)"
    if [ "$mode" = "own" ]; then
      oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-og
  namespace: ${ns}
spec:
  targetNamespaces:
    - ${ns}
EOF
    else
      oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-og
  namespace: ${ns}
spec: {}
EOF
    fi
  elif [ "$count" -eq 1 ]; then
    echo "  [$ns] 已有 1 個 OperatorGroup，沿用不動"
  else
    echo "  [$ns] !!! 有 $count 個 OperatorGroup，OLM 會失敗，請手動清到剩一個:"
    oc get operatorgroup -n "$ns"
    exit 1
  fi
done

echo ">>> 完成。觀察安裝狀態:"
echo "    oc get csv -A | grep -v Succeeded"
