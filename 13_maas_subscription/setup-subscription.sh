#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 14. 訂閱 MaaS 模型自動化
#   14.1: MaaSModelRef + MaaSSubscription
#   14.2: 透過 maas-api 建立 API Key
#   14.3: 用 API Key 測試 vLLM 與 llm-d 推理端點
# 需要: oc, jq, curl
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=demo
DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
MAAS="https://maas.${DOMAIN}"

# ---------- 14.1: Subscription ----------
echo ">>> 14.1 建立 MaaSModelRef + MaaSSubscription"
oc apply -f subscription.yaml

echo ">>> 等待 Subscription Ready"
for i in $(seq 1 30); do
  st=$(oc get maassubscription demo-subscription -n models-as-a-service \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ -z "$st" ] && st=$(oc get maassubscription demo-subscription -n models-as-a-service \
       -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  [ "$st" = "True" ] && echo "    Ready" && break
  sleep 5
  [ "$i" -eq 30 ] && echo "    (未看到 Ready condition，繼續嘗試建 API Key)"
done

# ---------- 14.2: API Key ----------
echo ">>> 14.2 建立 API Key (經 maas-api)"
RESP=$(curl -sk -X POST "${MAAS}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"demo-key-$(date +%s)\", \"expiration\": \"4h\"}")
API_KEY=$(echo "$RESP" | jq -r '.token // .apiKey // .api_key // .key // .secret // empty')
if [ -z "$API_KEY" ]; then
  echo "!!! 取得 API Key 失敗，maas-api 回應:"; echo "$RESP" | jq . 2>/dev/null || echo "$RESP"
  echo "    診斷: oc logs -n redhat-ods-applications deploy/maas-api --tail=30"
  echo "          oc get maassubscription demo-subscription -n models-as-a-service -o jsonpath='{.status}' | jq ."
  echo "    若 TRLP 顯示 'Gateway API provider is not installed':"
  echo "          oc delete pod --all -n rhcl-operator && oc delete pod --all -n kuadrant-system"
  exit 1
fi
echo "API_KEY=${API_KEY}" > maas-api-key.env
chmod 600 maas-api-key.env
echo "    API Key 已存到 13_maas_subscription/maas-api-key.env (效期 4h)"

# ---------- 14.3: 測試 ----------
VLLM_EP="${MAAS}/${NS}/qwen3-14b-vllm"
LLMD_EP="${MAAS}/${NS}/qwen3-14b-llmd"

test_model() { # test_model <endpoint> <model-name>
  local ep="$1" model="$2"
  echo ""
  echo ">>> 測試 ${model}"
  echo "--- GET ${ep}/v1/models"
  curl -sk "${ep}/v1/models" -H "Authorization: Bearer ${API_KEY}" | jq -c '.data[]?.id // .' || true
  echo "--- POST chat/completions"
  curl -sk "${ep}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"你好！請用繁體中文回應我！\"}],
      \"max_tokens\": 256
    }" | jq -r '.choices[0].message.content // .' || true
}

test_model "$VLLM_EP" "qwen3-14b-vllm"
test_model "$LLMD_EP" "qwen3-14b-llmd"

echo ""
echo ">>> 完成。後續使用:"
echo "    source 13_maas_subscription/maas-api-key.env"
echo "    curl -sk ${VLLM_EP}/v1/chat/completions -H \"Authorization: Bearer \$API_KEY\" ..."
