#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 9.4 llm-d 認證: 建立推論用 ServiceAccount
# 用法: ./create-llm-user.sh [namespace]   (預設 demo)
# 之後取 token: oc create token llm-user -n <ns> --duration=1h
# =============================================================
set -euo pipefail
NAMESPACE="${1:-demo}"

oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc new-project "$NAMESPACE" >/dev/null

oc create serviceaccount llm-user -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: llm-access
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: llm-user-binding
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: llm-access
subjects:
  - kind: ServiceAccount
    name: llm-user
    namespace: ${NAMESPACE}
EOF

echo ">>> 完成。取得 1 小時效期的 JWT:"
echo "    TOKEN=\$(oc create token llm-user -n ${NAMESPACE} --duration=1h)"
