#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 8. 配置 llm-d 自動化
#   8.1: 確認 Service Mesh v2 未安裝
#   8.2: 推論 Gateway (ConfigMap + Gateway + Route) 與驗證
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

# ---------- 8.1: Service Mesh 版本檢查 ----------
echo ">>> 7.1 檢查 Service Mesh 版本"
if oc get csv -A -o custom-columns="NAME:.metadata.name" --no-headers 2>/dev/null \
   | grep -E '^servicemeshoperator\.v2' | head -1 | grep -q .; then
  echo "!!! 偵測到 Service Mesh v2，與 llm-d 不相容，請先移除"; exit 1
fi
oc get csv -A -o custom-columns="NAME:.metadata.name" --no-headers | grep servicemeshoperator3 | head -1 \
  && echo "    Service Mesh 3 OK"

# 確認 GatewayClass (§7 前提)
oc get gatewayclass data-science-gateway-class >/dev/null \
  || { echo "!!! data-science-gateway-class 不存在，先完成 06_rhoai"; exit 1; }

# ---------- 8.2-1/2: ConfigMap + Gateway ----------
echo ">>> 7.2 建立推論 Gateway"
oc apply -f inference-gateway.yaml

# ---------- 8.2-3: Route (host 依叢集網域產生) ----------
DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')  # apps.<base_domain>
HOST="inference.${DOMAIN}"
echo ">>> 7.3 建立 Route: https://${HOST}"
oc apply -f - <<EOF
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  host: ${HOST}
  to:
    kind: Service
    name: openshift-ai-inference-data-science-gateway-class
    weight: 100
  port:
    targetPort: 443
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# ---------- 8.2-4: 驗證 ----------
echo ">>> 7.4 等待 Gateway Programmed"
for i in $(seq 1 30); do
  st=$(oc get gateway openshift-ai-inference -n openshift-ingress \
       -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [ "$st" = "True" ] && echo "    Programmed" && break
  sleep 10
  [ "$i" -eq 30 ] && { echo "!!! Gateway 未 Programmed: oc describe gateway openshift-ai-inference -n openshift-ingress"; exit 1; }
done
oc get gateway -n openshift-ingress
echo ">>> llm-d Gateway 完成。推論端點: https://${HOST}"
echo "    (部署模型後可用 ./create-llm-user.sh <namespace> 建立呼叫用的 ServiceAccount)"
