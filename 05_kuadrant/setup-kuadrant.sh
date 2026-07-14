#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 6. 設定 Kuadrant 自動化
#   6-1/6-2: 建立 kuadrant-system + Kuadrant CR (observability)
#   6-3: 等 Authorino Service 出現後加 serving-cert annotation
#   6-4: Authorino 啟用 SSL
#   6-5: Authorino deployment 設定 TLS CA 環境變數
#   6-6: 驗證
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=kuadrant-system

# ---------- 6-1 / 6-2: Namespace + Kuadrant CR ----------
echo ">>> 建立 kuadrant-system 與 Kuadrant CR"
# 先只套 Namespace + Kuadrant (Authorino CR 要等 service annotate 完)
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: kuadrant-system
EOF
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec:
  observability:
    enable: true
EOF

# ---------- 6-3: 等 Authorino Service 出現, 加 serving-cert annotation ----------
echo ">>> 等待 authorino-authorino-authorization Service"
for i in $(seq 1 60); do
  oc get svc authorino-authorino-authorization -n $NS >/dev/null 2>&1 && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! Authorino Service 未出現，檢查: oc get pods -n $NS"; exit 1; }
done
oc annotate svc/authorino-authorino-authorization -n $NS \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
echo "    annotation 已設定"

# 等 service-ca 簽出憑證
echo ">>> 等待 authorino-server-cert Secret"
for i in $(seq 1 30); do
  oc get secret authorino-server-cert -n $NS >/dev/null 2>&1 && break
  sleep 5
  [ "$i" -eq 30 ] && { echo "!!! serving cert 未產生"; exit 1; }
done

# ---------- 6-4: Authorino 啟用 SSL ----------
echo ">>> 更新 Authorino 啟用 SSL"
oc apply -f - <<'EOF'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

# ---------- 6-5: TLS certificate validation 環境變數 ----------
echo ">>> 設定 Authorino deployment 環境變數"
oc -n $NS set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
oc rollout status deployment/authorino -n $NS --timeout=180s

# ---------- 6-6: 驗證 ----------
echo ">>> 驗證"
oc get kuadrant kuadrant -n $NS
echo "--- PodMonitor (觀測堆疊):"
oc get podmonitor kuadrant-limitador-monitor -n $NS 2>/dev/null \
  || echo "    (kuadrant-limitador-monitor 尚未出現，observability 元件可能還在部署)"
echo "--- Authorino env (確認未被 operator 洗掉):"
oc get deployment authorino -n $NS -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
echo ">>> Kuadrant 設定完成"
