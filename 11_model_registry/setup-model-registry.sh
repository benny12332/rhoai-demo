#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 12. Model Registry 自動化
#   12.1: MariaDB + ModelRegistry CR, 等 Ready
#   12.2: 透過 Model Registry REST API 註冊 Qwen3 模型
# 可重複執行 (idempotent)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

REG_NS=rhoai-model-registries
REG_NAME=demo-registry
MODEL_NAME=qwen3-14b-w4a16
MODEL_URI="pvc://models/Qwen3-14B-quantized.w4a16"

# ---------- 12.1: 資料庫 ----------
echo ">>> 11.1 部署 MariaDB"
oc get ns $REG_NS >/dev/null 2>&1 || oc create ns $REG_NS
oc apply -f mariadb.yaml
oc rollout status statefulset/mariadb -n $REG_NS --timeout=300s

# ---------- 12.1: ModelRegistry CR ----------
echo ">>> 11.2 建立 ModelRegistry"
oc apply -f - <<EOF
apiVersion: modelregistry.opendatahub.io/v1beta1
kind: ModelRegistry
metadata:
  name: ${REG_NAME}
  namespace: ${REG_NS}
  annotations:
    openshift.io/display-name: ${REG_NAME}
spec:
  grpc: {}
  rest: {}
  # 認證交給 operator 預設的 kubeRBACProxy (3.4 不可與 oauthProxy 並用)
  mysql:
    host: mariadb.${REG_NS}.svc.cluster.local
    port: 3306
    database: registry
    username: admin
    passwordSecret:
      name: mariadb-password
      key: database-password
    skipDBCreation: false
EOF

echo ">>> 11.3 等待 ModelRegistry Available"
for i in $(seq 1 60); do
  # 注意: 叢集有兩個 modelregistry 同名 CRD, 必須用完整資源名
  st=$(oc get modelregistries.modelregistry.opendatahub.io ${REG_NAME} -n $REG_NS \
       -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  [ "$st" = "True" ] && echo "    Available" && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! ModelRegistry 未 Ready: oc describe modelregistries.modelregistry.opendatahub.io ${REG_NAME} -n $REG_NS"; exit 1; }
done

# ---------- 12.2: 註冊模型 (REST API, 經 port-forward) ----------
echo ">>> 11.4 註冊模型: ${MODEL_NAME}"
oc port-forward -n $REG_NS "svc/${REG_NAME}" 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

API="http://localhost:18080/api/model_registry/v1alpha3"
AUTH="Authorization: Bearer $(oc whoami -t)"

# RegisteredModel (已存在則取回)
RM_ID=$(curl -sf "$API/registered_models?name=${MODEL_NAME}" -H "$AUTH" | jq -r '.items[0].id // empty' || true)
if [ -z "$RM_ID" ]; then
  RM_ID=$(curl -sf -X POST "$API/registered_models" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${MODEL_NAME}\",\"description\":\"Qwen3 14B W4A16 quantized (RedHatAI)\"}" | jq -r .id)
  echo "    RegisteredModel id=$RM_ID"
else
  echo "    RegisteredModel 已存在 id=$RM_ID"
fi

# ModelVersion
MV_ID=$(curl -sf "$API/registered_models/${RM_ID}/versions" -H "$AUTH" | jq -r '.items[] | select(.name=="1") | .id' | head -1 || true)
if [ -z "$MV_ID" ]; then
  MV_ID=$(curl -sf -X POST "$API/model_versions" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"name\":\"1\",\"registeredModelId\":\"${RM_ID}\"}" | jq -r .id)
  echo "    ModelVersion id=$MV_ID"
else
  echo "    ModelVersion 已存在 id=$MV_ID"
fi

# ModelArtifact (模型位置)
ART=$(curl -sf "$API/model_versions/${MV_ID}/artifacts" -H "$AUTH" | jq -r '.items[0].id // empty' || true)
if [ -z "$ART" ]; then
  curl -sf -X POST "$API/model_versions/${MV_ID}/artifacts" -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"artifactType\":\"model-artifact\",\"name\":\"${MODEL_NAME}\",\"uri\":\"${MODEL_URI}\",\"modelFormatName\":\"vLLM\"}" >/dev/null
  echo "    ModelArtifact 已建立 (uri=${MODEL_URI})"
else
  echo "    ModelArtifact 已存在"
fi

# 給 12_deploy_model 用 (deployment 標籤可回連 registry)
cat > registry-ids.env <<EOF
REGISTERED_MODEL_ID=${RM_ID}
MODEL_VERSION_ID=${MV_ID}
EOF
echo ">>> 完成。Dashboard > Model Registry 應可看到 ${MODEL_NAME}"
