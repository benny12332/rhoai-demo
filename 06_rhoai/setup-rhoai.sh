#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 7. 配置 RHOAI 自動化
#   7.1: 確認 rhods-operator 已就緒 (安裝在 01_install_operator)
#   7.2: 建立 DataScienceCluster 並等待 Ready
#   7.3: 覆蓋 OdhDashboardConfig
#   最後驗證 GatewayClass 與 Pods
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NS=redhat-ods-applications

# ---------- 7.1: 確認 RHOAI Operator ----------
echo ">>> 7.1 等待 rhods-operator CSV Succeeded"
for i in $(seq 1 60); do
  phase=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].status.phase}' 2>/dev/null || true)
  [ "$phase" = "Succeeded" ] && echo "    OK" && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! rhods-operator 未就緒，先跑 01_install_operator/install.sh"; exit 1; }
done

# 等 DSCInitialization (operator 自動建立)
echo ">>> 等待 DSCInitialization Ready"
for i in $(seq 1 30); do
  st=$(oc get dscinitialization -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [ "$st" = "Ready" ] && echo "    OK" && break
  sleep 10
  [ "$i" -eq 30 ] && echo "    (DSCI 未 Ready，仍繼續嘗試建立 DSC)"
done

# ---------- 7.2: DataScienceCluster ----------
echo ">>> 7.2 建立 DataScienceCluster"
oc apply -f datasciencecluster.yaml

# 不等 DSC Ready，依手冊只驗證 GatewayClass 與 dashboard 部署出現即可
echo ">>> 等待 GatewayClass data-science-gateway-class"
for i in $(seq 1 60); do
  acc=$(oc get gatewayclass data-science-gateway-class -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [ "$acc" = "True" ] && echo "    Accepted" && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! GatewayClass 未建立，檢查: oc describe dsc default-dsc"; exit 1; }
done

echo ">>> 等待 rhods-dashboard deployment 出現 (7.3 需要)"
for i in $(seq 1 60); do
  oc get deployment rhods-dashboard -n $APP_NS >/dev/null 2>&1 && echo "    OK" && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! rhods-dashboard 未出現"; exit 1; }
done

# ---------- 7.3: OdhDashboardConfig ----------
echo ">>> 7.3 套用 OdhDashboardConfig"
# operator 會先建一份預設值，用 server-side apply 覆蓋
oc apply --server-side --force-conflicts -f odh-dashboard-config.yaml
# 重啟 dashboard 讓設定生效
oc rollout restart deployment/rhods-dashboard -n $APP_NS
oc rollout status deployment/rhods-dashboard -n $APP_NS --timeout=300s

# ---------- 驗證 ----------
echo ">>> 驗證"
echo "--- GatewayClass:"
oc get gatewayclass data-science-gateway-class
echo "--- $APP_NS 異常 Pods (無輸出 = 全部正常):"
oc get pod -n $APP_NS --no-headers | grep -vE 'Running|Completed' || true
echo "--- Dashboard URL:"
oc get route rhods-dashboard -n $APP_NS -o jsonpath='https://{.spec.host}{"\n"}' 2>/dev/null || true
echo ">>> RHOAI 配置完成"
