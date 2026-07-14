#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 監控設定自動化 (手冊第 4 大項完整流程)
#   1. 啟用 User Workload Monitoring (智慧合併既有設定)
#   2. 驗證 UWM pods
#   3-5. 部署 Grafana + SA + 權限 + Token
#   6. 自動佈建 Prometheus (Thanos Querier) datasource
#   7. 自動匯入 dashboards/ 下的所有儀表板
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=utilities

# ---------- 1. 啟用 User Workload Monitoring ----------
echo ">>> 1. 啟用 User Workload Monitoring"
if oc get cm cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  cur=$(oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}')
  if echo "$cur" | grep -q 'enableUserWorkload: *true'; then
    echo "    已啟用，跳過"
  elif echo "$cur" | grep -q 'enableUserWorkload: *false'; then
    new=$(echo "$cur" | sed 's/enableUserWorkload: *false/enableUserWorkload: true/')
    oc create cm cluster-monitoring-config -n openshift-monitoring \
      --from-literal=config.yaml="$new" --dry-run=client -o yaml | oc apply -f -
    echo "    false -> true"
  else
    new=$(printf '%s\nenableUserWorkload: true\n' "$cur")
    oc create cm cluster-monitoring-config -n openshift-monitoring \
      --from-literal=config.yaml="$new" --dry-run=client -o yaml | oc apply -f -
    echo "    已附加 enableUserWorkload: true (保留原設定)"
  fi
else
  oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
  echo "    ConfigMap 已建立"
fi

# ---------- 2. 驗證 UWM pods ----------
echo ">>> 2. 等待 user workload monitoring pods"
for i in $(seq 1 30); do
  n=$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running || true)
  [ "$n" -ge 2 ] && echo "    $n 個 pods Running" && break
  sleep 10
  [ "$i" -eq 30 ] && { echo "!!! UWM pods 未啟動"; exit 1; }
done

# ---------- 6a. 產生 datasource ConfigMap (需在 Grafana 啟動前) ----------
echo ">>> 準備 Grafana provisioning ConfigMaps"
oc get ns $NS >/dev/null 2>&1 || oc create ns $NS
# 先建 SA/Secret (token 需要時間產生)
oc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: {name: grafana, namespace: $NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-sa-token
  namespace: $NS
  annotations: {kubernetes.io/service-account.name: grafana}
type: kubernetes.io/service-account-token
EOF

echo ">>> 取得 SA token 與 Thanos Querier 位置"
TOKEN=""
for i in $(seq 1 12); do
  TOKEN=$(oc get secret grafana-sa-token -n $NS -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$TOKEN" ] && break
  sleep 5
done
[ -z "$TOKEN" ] && { echo "!!! 取不到 grafana-sa-token"; exit 1; }
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
echo "    Thanos: https://${THANOS_HOST}"

# 手冊 4-6: datasource 佈建 (取代 GUI 手動設定)
oc create cm grafana-datasources -n $NS --dry-run=client -o yaml \
  --from-literal=datasources.yaml="$(cat <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: https://${THANOS_HOST}
    isDefault: true
    editable: true
    jsonData:
      httpHeaderName1: Authorization
      tlsSkipVerify: true
      timeInterval: "5s"
    secureJsonData:
      httpHeaderValue1: Bearer ${TOKEN}
EOF
)" | oc apply -f -

# 手冊 4-7: dashboard provider + 儀表板 JSON
oc create cm grafana-dashboard-provider -n $NS --dry-run=client -o yaml \
  --from-literal=provider.yaml="$(cat <<'EOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF
)" | oc apply -f -

if ls dashboards/*.json >/dev/null 2>&1; then
  oc create cm grafana-dashboards -n $NS --dry-run=client -o yaml \
    $(for f in dashboards/*.json; do printf -- '--from-file=%s ' "$f"; done) | oc apply -f -
  echo "    已匯入 $(ls dashboards/*.json | wc -l | tr -d ' ') 個儀表板"
else
  echo "    dashboards/ 沒有 JSON，先執行 ./download-dashboards.sh"
fi

# ---------- 3-5. 部署 Grafana ----------
echo ">>> 部署 Grafana"
oc apply -f grafana.yaml
oc rollout restart deployment/grafana -n $NS >/dev/null 2>&1 || true
oc rollout status deployment/grafana -n $NS --timeout=300s

echo ""
echo ">>> 完成！Grafana 位置 (預設帳密 admin/admin):"
echo "    https://$(oc get route grafana -n $NS -o jsonpath='{.spec.host}')"
