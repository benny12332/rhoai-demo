#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - 手冊 11. 建立 Workbench 自動化
#   11-1: 建立 demo 專案 + PVC
#   11-4: 以 Job 下載 Qwen3-14B-quantized.w4a16 到 models PVC
#   11-2: 建立 Workbench (Notebook CR, L40S hardware profile)
#   11-3: 等 Workbench Ready 並印出網址
# 說明: Workbench image 動態從叢集 imagestream 取得, 不寫死版本
# 可重複執行 (idempotent; 模型已下載會自動跳過)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=demo
WB=qwen-workbench
IS_NS=redhat-ods-applications

# ---------- 11-1: 專案 + 儲存 ----------
echo ">>> 11-1 建立專案與 PVC"
oc apply -f project-and-storage.yaml

# ---------- 11-4: 模型下載 Job (先跑, RWO PVC 避免與 Workbench 搶掛載) ----------
echo ">>> 11-4 下載模型 (Job)"
if oc get job download-qwen3-14b -n $NS >/dev/null 2>&1; then
  st=$(oc get job download-qwen3-14b -n $NS -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  if [ "$st" = "1" ]; then
    echo "    Job 已成功過，跳過"
  else
    echo "    移除舊 Job 重跑"
    oc delete job download-qwen3-14b -n $NS --ignore-not-found
    oc apply -f download-model-job.yaml
  fi
else
  oc apply -f download-model-job.yaml
fi
echo ">>> 等待模型下載完成 (~10GB, 視網速約 5-20 分鐘)"
oc wait --for=condition=complete job/download-qwen3-14b -n $NS --timeout=3600s
echo "    模型下載完成"

# ---------- 11-2: Workbench ----------
echo ">>> 11-2 選擇 Workbench image"
# 注意: 要選 notebook image (含 Jupyter server)，不能選 runtime-* (pipeline 用, 會 CrashLoop)
# 可用環境變數覆蓋: WB_IMAGE_STREAM=pytorch WB_IMAGE_TAG=3.4 ./setup-workbench.sh
IS_NAME="${WB_IMAGE_STREAM:-}"
if [ -z "$IS_NAME" ]; then
  for cand in s2i-generic-data-science-notebook pytorch minimal-gpu; do
    oc get imagestream "$cand" -n $IS_NS >/dev/null 2>&1 && IS_NAME=$cand && break
  done
fi
if [ -z "$IS_NAME" ]; then
  echo "!!! 找不到 notebook imagestream，現有 imagestream 如下:"
  oc get imagestream -n $IS_NS
  exit 1
fi
# tag 選擇順序: 環境變數 > Dashboard 標記 recommended 的 tag > 最大版本
TAG="${WB_IMAGE_TAG:-}"
[ -z "$TAG" ] && TAG=$(oc get imagestream "$IS_NAME" -n $IS_NS -o json \
  | jq -r '[.spec.tags[] | select(.annotations["opendatahub.io/workbench-image-recommended"]=="true")][0].name // empty')
[ -z "$TAG" ] && TAG=$(oc get imagestream "$IS_NAME" -n $IS_NS -o jsonpath='{.spec.tags[*].name}' \
  | tr ' ' '\n' | sort -V | tail -1)
IMAGE="image-registry.openshift-image-registry.svc:5000/${IS_NS}/${IS_NAME}:${TAG}"
echo "    使用 image: ${IS_NAME}:${TAG}"

echo ">>> 建立 Workbench ServiceAccount"
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${WB}
  namespace: ${NS}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.notebook: >-
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"${WB}"}}
EOF

echo ">>> 建立 Workbench (Notebook CR)"
oc apply -f - <<EOF
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: ${WB}
  namespace: ${NS}
  labels:
    app: ${WB}
    opendatahub.io/dashboard: "true"
    opendatahub.io/odh-managed: "true"
  annotations:
    openshift.io/display-name: ${WB}
    opendatahub.io/hardware-profile-name: nvidia-l40s
    opendatahub.io/hardware-profile-namespace: ${IS_NS}
    notebooks.opendatahub.io/inject-oauth: "true"
    notebooks.opendatahub.io/last-image-selection: '${IS_NAME}:${TAG}'
spec:
  template:
    spec:
      serviceAccountName: ${WB}
      containers:
        - name: ${WB}
          image: ${IMAGE}
          env:
            - name: NOTEBOOK_ARGS
              value: |-
                --ServerApp.port=8888
                --ServerApp.token=''
                --ServerApp.password=''
                --ServerApp.base_url=/notebook/${NS}/${WB}
                --ServerApp.quit_button=False
          ports:
            - name: notebook-port
              containerPort: 8888
              protocol: TCP
          # 對應 nvidia-l40s hardware profile 預設值
          resources:
            requests:
              cpu: "8"
              memory: 64Gi
              nvidia.com/gpu: "1"
            limits:
              cpu: "8"
              memory: 64Gi
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: workspace
              mountPath: /opt/app-root/src
            - name: models
              mountPath: /opt/app-root/src/models
      # GPU 節點 taint 對應 (與 hardware profile 一致)
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        node-role.kubernetes.io/gpu: ''
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: ${WB}
        - name: models
          persistentVolumeClaim:
            claimName: models
EOF

# ---------- 11-3: 驗證 ----------
echo ">>> 等待 Workbench Ready"
for i in $(seq 1 60); do
  ready=$(oc get pod -n $NS -l app=${WB} -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || true)
  echo "$ready" | grep -q true && ! echo "$ready" | grep -q false && echo "    Workbench Running" && break
  sleep 10
  [ "$i" -eq 60 ] && { echo "!!! Workbench 未 Ready: oc describe pod -n $NS -l app=${WB}"; exit 1; }
done

echo ""
echo ">>> 完成！"
echo "    Workbench: https://$(oc get route ${WB} -n ${NS} -o jsonpath='{.spec.host}' 2>/dev/null || echo '<route 由 notebook controller 建立中>')"
echo "    模型位置: ~/models/Qwen3-14B-quantized.w4a16"
