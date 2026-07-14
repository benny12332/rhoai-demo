#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 14.3 測試 LLM 推理
# 用法:
#   ./test-inference.sh                     # 測 vLLM + llm-d 兩個端點
#   ./test-inference.sh qwen3-14b-vllm      # 只測指定模型
#   PROMPT="講個笑話" ./test-inference.sh    # 自訂提問
# API Key: 讀 maas-api-key.env, 不存在或過期自動向 maas-api 重新申請
# 需要: oc, jq, curl
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=demo
MODELS=("${@:-qwen3-14b-vllm qwen3-14b-llmd}")
[ $# -eq 0 ] && MODELS=(qwen3-14b-vllm qwen3-14b-llmd)
PROMPT="${PROMPT:-你好！請用繁體中文回應我！}"

DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
MAAS="https://maas.${DOMAIN}"

# ---------- API Key (自動續發) ----------
get_new_key() {
  echo ">>> 向 maas-api 申請新 API Key (效期 4h)"
  code=$(curl -sk -o /tmp/maas-token.json -w '%{http_code}' -X POST "${MAAS}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer $(oc whoami -t)" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"demo-key-$(date +%s)\", \"expiration\": \"4h\"}")
  API_KEY=$(jq -r '.token // .apiKey // .api_key // .key // .secret // empty' /tmp/maas-token.json 2>/dev/null || true)
  if [ "$code" != "200" ] && [ "$code" != "201" ] || [ -z "$API_KEY" ]; then
    echo "!!! 申請失敗 (HTTP $code)，原始回應:"
    cat /tmp/maas-token.json; echo
    echo "    診斷: oc get route -n models-as-a-service"
    echo "          oc logs -n models-as-a-service -l app=maas-api --tail=20"
    exit 1
  fi
  echo "API_KEY=${API_KEY}" > maas-api-key.env && chmod 600 maas-api-key.env
}

if [ -f maas-api-key.env ]; then
  # shellcheck disable=SC1091
  source maas-api-key.env
  # 驗證 key 是否仍有效 (拿第一個模型的 /v1/models 試)
  first_ep="${MAAS}/${NS}/${MODELS[0]}"
  code=$(curl -sk -o /dev/null -w '%{http_code}' "${first_ep}/v1/models" \
         -H "Authorization: Bearer ${API_KEY}" || echo 000)
  [ "$code" = "401" ] || [ "$code" = "403" ] && { echo ">>> 既有 Key 已失效 (HTTP $code)"; get_new_key; }
else
  get_new_key
fi

# ---------- 測試 ----------
PASS=0; FAIL=0
for m in "${MODELS[@]}"; do
  EP="${MAAS}/${NS}/${m}"
  echo ""
  echo "================ ${m} ================"
  echo "端點: ${EP}"

  # 1) 列出模型
  echo "--- [1/2] GET /v1/models"
  code=$(curl -sk -o /tmp/models.json -w '%{http_code}' "${EP}/v1/models" \
         -H "Authorization: Bearer ${API_KEY}")
  if [ "$code" = "200" ]; then
    echo "OK (200): $(jq -r '[.data[].id] | join(", ")' /tmp/models.json)"
  else
    echo "FAIL (HTTP $code): $(cat /tmp/models.json)"; FAIL=$((FAIL+1)); continue
  fi

  # 2) chat completion
  echo "--- [2/2] POST /v1/chat/completions"
  start=$(date +%s)
  code=$(curl -sk -o /tmp/chat.json -w '%{http_code}' "${EP}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${m}\",
      \"messages\": [{\"role\": \"user\", \"content\": $(jq -Rn --arg p "$PROMPT" '$p')}],
      \"max_tokens\": 1024
    }")
  elapsed=$(( $(date +%s) - start ))
  if [ "$code" = "200" ]; then
    echo "OK (200, ${elapsed}s, tokens: $(jq -r '.usage.total_tokens // "?"' /tmp/chat.json))"
    echo "--- 回應:"
    jq -r '.choices[0].message.content' /tmp/chat.json
    PASS=$((PASS+1))
  else
    echo "FAIL (HTTP $code): $(cat /tmp/chat.json)"; FAIL=$((FAIL+1))
  fi
done

echo ""
echo "================ 結果 ================"
echo "通過: ${PASS} / $((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
