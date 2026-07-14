#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 13. 部署模型自動化 (vLLM + llm-d)
# 前提: 07_llmd / 08_maas 已完成, demo/models PVC 內已有模型
# 注意: models PVC 是 RWO(EBS), 建議先停 Workbench 釋放掛載
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=demo

# 模型改用 hf:// 直接下載, 不再掛 models PVC, 無 RWO 衝突問題

echo ">>> 13.1 部署 vLLM 版本"
oc apply -f llmisvc-qwen3-vllm.yaml
echo ">>> 13.2 部署 llm-d 版本"
oc apply -f llmisvc-qwen3-llmd.yaml

# 若 11_model_registry 有註冊，補上關聯標籤 (Dashboard 可從 Registry 追蹤部署)
if [ -f ../11_model_registry/registry-ids.env ]; then
  # shellcheck disable=SC1091
  source ../11_model_registry/registry-ids.env
  for m in qwen3-14b-vllm qwen3-14b-llmd; do
    oc label llminferenceservice $m -n $NS --overwrite \
      modelregistry.opendatahub.io/registered-model-id="${REGISTERED_MODEL_ID}" \
      modelregistry.opendatahub.io/model-version-id="${MODEL_VERSION_ID}" || true
  done
  echo ">>> 已標記 Model Registry 關聯 (model=${REGISTERED_MODEL_ID}, version=${MODEL_VERSION_ID})"
fi

echo ">>> 等待模型 Ready (載入 ~10GB 權重, 約 5-15 分鐘)"
for m in qwen3-14b-vllm qwen3-14b-llmd; do
  for i in $(seq 1 90); do
    st=$(oc get llminferenceservice $m -n $NS \
         -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$st" = "True" ] && echo "    $m Ready" && break
    sleep 10
    [ "$i" -eq 90 ] && echo "!!! $m 未 Ready: oc describe llminferenceservice $m -n $NS"
  done
done

DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo ""
echo ">>> 完成。MaaS 端點 (訂閱與 API Key 見手冊 §14):"
echo "    https://maas.${DOMAIN}/${NS}/qwen3-14b-vllm/v1"
echo "    https://maas.${DOMAIN}/${NS}/qwen3-14b-llmd/v1"
oc get llminferenceservice -n $NS
