#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 9. 配置 Model as a Service (MaaS) 自動化
#   9.1: Postgres + maas-db-config Secret
#   9.2: MaaS Gateway (ConfigMap + Gateway + Route) 與驗證
# 前提: §7 已完成 (data-science-gateway-class)
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NS=redhat-ods-applications

# ---------- 9.1: 資料庫 ----------
echo ">>> 9.1 部署 Postgres"
oc apply -f postgres.yaml
echo ">>> 等待 Postgres Ready"
oc rollout status statefulset/postgresql -n $APP_NS --timeout=300s

echo ">>> 建立 maas-db-config Secret"
oc create secret generic maas-db-config -n $APP_NS \
  --from-literal=DB_CONNECTION_URL="postgresql://maasadmin:maaspassword@postgresql.${APP_NS}.svc.cluster.local:5432/maasdb" \
  --dry-run=client -o yaml | oc apply -f -

# ---------- 9.2: Gateway ----------
oc get gatewayclass data-science-gateway-class >/dev/null \
  || { echo "!!! data-science-gateway-class 不存在，先完成 06_rhoai"; exit 1; }

echo ">>> 9.2 建立 MaaS Gateway"
oc apply -f maas-gateway.yaml

DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')  # apps.<base_domain>
HOST="maas.${DOMAIN}"
echo ">>> 建立 Route: https://${HOST}"
oc apply -f - <<EOF
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  host: ${HOST}
  to:
    kind: Service
    name: maas-default-gateway-data-science-gateway-class
    weight: 100
  port:
    targetPort: 443
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# ---------- 9.2-4: 驗證 ----------
echo ">>> 等待 MaaS Gateway Programmed"
for i in $(seq 1 30); do
  st=$(oc get gateway maas-default-gateway -n openshift-ingress \
       -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [ "$st" = "True" ] && echo "    Programmed" && break
  sleep 10
  [ "$i" -eq 30 ] && { echo "!!! Gateway 未 Programmed: oc describe gateway maas-default-gateway -n openshift-ingress"; exit 1; }
done
oc get gateway -n openshift-ingress
echo ">>> MaaS 完成。端點: https://${HOST}"
