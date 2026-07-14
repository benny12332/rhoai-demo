#!/usr/bin/env bash
# =============================================================
# 準備 Grafana dashboard JSON 到 dashboards/
# 優先使用 00_prepare/source/dashboards/ 的離線副本 (執行機不需上網),
# 沒有才從 GitHub / grafana.com 下載
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dashboards

SRC="../00_prepare/source/dashboards"
FILES="dcgm-exporter-dashboard.json nvidia-mig-dashboard.json vllm-dashboard.json maas-token-metrics-dashboard.json"

# ---------- 離線來源 ----------
if [ -d "$SRC" ]; then
  missing=0
  for f in $FILES; do
    if [ -s "$SRC/$f" ]; then
      cp "$SRC/$f" dashboards/
    else
      echo "!!! 離線來源缺 $f"; missing=1
    fi
  done
  if [ "$missing" -eq 0 ]; then
    echo ">>> 已從 00_prepare/source/dashboards 複製 4 個儀表板 (離線模式)"
    exit 0
  fi
  echo ">>> 離線來源不完整，改用網路下載補齊"
fi

# ---------- 網路下載 (fallback) ----------
cd dashboards

[ -s dcgm-exporter-dashboard.json ] || curl -sfL \
  https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/grafana/dcgm-exporter-dashboard.json \
  -o dcgm-exporter-dashboard.json

[ -s nvidia-mig-dashboard.json ] || curl -sfL \
  https://grafana.com/api/dashboards/23382/revisions/latest/download \
  -o nvidia-mig-dashboard.json

if [ ! -s vllm-dashboard.json ]; then
  curl -sfL https://raw.githubusercontent.com/rh-aiservices-bu/rhoai-uwm/main/rhoai-uwm-grafana/overlays/rhoai-uwm-user-grafana-app/grafana-vllm-dashboard.yaml \
    -o /tmp/vllm-dashboard-cr.yaml
  awk '/^  json: \|/{f=1;next} f && /^[^ ]/{f=0} f{sub(/^    /,""); print}' \
    /tmp/vllm-dashboard-cr.yaml > vllm-dashboard.json
fi

[ -s maas-token-metrics-dashboard.json ] || curl -sfL \
  https://raw.githubusercontent.com/opendatahub-io/models-as-a-service/main/docs/samples/dashboards/maas-token-metrics-dashboard.json \
  -o maas-token-metrics-dashboard.json

# ---------- 驗證 ----------
for f in $FILES; do
  python3 -c "import json;json.load(open('$f'))" && echo "OK  $f" || { echo "BAD $f"; exit 1; }
done
