#!/usr/bin/env bash
# =============================================================
# RHOAI 3.4 Demo - 總控安裝程序
# 依序執行 00_prepare ~ 13_maas_subscription
# 每個 stage: 前置檢查 -> 執行 -> 完成驗證 -> 記錄狀態
# 狀態存於 .demo_state, 可中斷後續跑; --reset 從頭開始
# 相容 macOS bash 3.2
# =============================================================
set -u
cd "$(dirname "$0")"

STATE_FILE=".demo_state"
[ "${1:-}" = "--reset" ] && rm -f "$STATE_FILE"
touch "$STATE_FILE"

# ---------- 顏色 ----------
R=$'\033[0m'; REV=$'\033[7m'; BOLD=$'\033[1m'
GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; CYN=$'\033[36m'

STAGES=(
  "00_prepare|登入 OCP / MachineSet (worker + GPU)"
  "01_install_operator|安裝 13 個 Operators"
  "02_GPU|NFD + GPU ClusterPolicy + nvidia-smi 驗證"
  "03_monitoring|UWM + Grafana + 儀表板"
  "04_jobset|JobSetOperator CR"
  "05_kuadrant|Kuadrant + Authorino TLS"
  "06_rhoai|DataScienceCluster + OdhDashboardConfig"
  "07_llmd|llm-d 推論 Gateway"
  "08_maas|MaaS Postgres + Gateway"
  "09_hardware_profile|GPU Hardware Profile (L40S)"
  "10_workbench|Workbench + 模型下載"
  "11_model_registry|Model Registry + 模型註冊"
  "12_deploy_model|部署 vLLM / llm-d 模型"
  "13_maas_subscription|MaaS 訂閱 + API Key + 推理測試"
)

is_done()   { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >> "$STATE_FILE"; }

# ---------- 共用檢查工具 ----------
need_login() {
  oc whoami >/dev/null 2>&1 && return 0
  echo "${RED}!!! 尚未登入 OCP (oc whoami 失敗)，請先完成 00_prepare${R}"; return 1
}
csv_ok() { # csv_ok <ns> <name-substr>
  oc get csv -n "$1" 2>/dev/null | grep "$2" | grep -q Succeeded
}
wait_for() { # wait_for "描述" 次數 間隔秒 指令...
  local desc="$1" tries="$2" gap="$3"; shift 3
  local i
  for i in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then echo "  ${GRN}OK${R} $desc"; return 0; fi
    sleep "$gap"
  done
  echo "  ${RED}TIMEOUT${R} $desc"; return 1
}
gw_programmed() {
  [ "$(oc get gateway "$1" -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" = "True" ]
}

# ---------- 各 stage: 前置檢查 ----------
pre_check() {
  case "$1" in
    00_prepare)
      command -v oc >/dev/null || { echo "${RED}需要 oc CLI${R}"; return 1; }
      command -v jq >/dev/null || { echo "${RED}需要 jq (brew install jq)${R}"; return 1; } ;;
    01_install_operator) need_login ;;
    02_GPU)
      need_login || return 1
      csv_ok openshift-nfd nfd || { echo "${RED}NFD Operator 未就緒，先完成 01${R}"; return 1; }
      csv_ok nvidia-gpu-operator gpu-operator || { echo "${RED}GPU Operator 未就緒，先完成 01${R}"; return 1; } ;;
    04_jobset)
      need_login || return 1
      csv_ok openshift-jobset-operator jobset || { echo "${RED}Job Set Operator 未就緒${R}"; return 1; } ;;
    05_kuadrant)
      need_login || return 1
      csv_ok openshift-operators rhcl-operator || { echo "${RED}RHCL Operator 未就緒${R}"; return 1; } ;;
    06_rhoai)
      need_login || return 1
      oc get csv -n redhat-ods-operator 2>/dev/null | grep -q 'rhods-operator\.3\.' \
        || { echo "${RED}RHOAI 3.x CSV 不存在 (channel 需 stable-3.4)${R}"; return 1; } ;;
    07_llmd|08_maas)
      need_login || return 1
      oc get gatewayclass data-science-gateway-class >/dev/null 2>&1 \
        || { echo "${RED}data-science-gateway-class 不存在，先完成 06${R}"; return 1; } ;;
    09_hardware_profile|10_workbench)
      need_login || return 1
      oc get ns redhat-ods-applications >/dev/null 2>&1 || { echo "${RED}RHOAI 未配置，先完成 06${R}"; return 1; } ;;
    11_model_registry)
      need_login || return 1
      oc get ns rhoai-model-registries >/dev/null 2>&1 || { echo "${RED}rhoai-model-registries 不存在，先完成 06${R}"; return 1; } ;;
    12_deploy_model)
      need_login || return 1
      gw_programmed maas-default-gateway || { echo "${RED}maas-default-gateway 未 Programmed，先完成 08${R}"; return 1; }
      gw_programmed openshift-ai-inference || { echo "${RED}openshift-ai-inference Gateway 未 Programmed，先完成 07${R}"; return 1; } ;;
    13_maas_subscription)
      need_login || return 1
      oc get llminferenceservice qwen3-14b-vllm -n demo >/dev/null 2>&1 \
        || { echo "${RED}模型未部署，先完成 12${R}"; return 1; } ;;
    *) need_login ;;
  esac
}

# ---------- 各 stage: 執行 ----------
do_exec() {
  case "$1" in
    00_prepare)           ./00_prepare/prepare.sh ;;
    01_install_operator)  ./01_install_operator/install.sh ;;
    02_GPU)               ./02_GPU/setup-gpu.sh ;;
    03_monitoring)
      ./03_monitoring/download-dashboards.sh   # 優先用 00_prepare/source 離線副本
      ./03_monitoring/setup-monitoring.sh ;;
    04_jobset)            oc apply -f 04_jobset/jobset-operator.yaml ;;
    05_kuadrant)          ./05_kuadrant/setup-kuadrant.sh ;;
    06_rhoai)             ./06_rhoai/setup-rhoai.sh ;;
    07_llmd)              ./07_llmd/setup-llmd.sh ;;
    08_maas)              ./08_maas/setup-maas.sh ;;
    09_hardware_profile)  oc apply -f 09_hardware_profile/hardware-profile-l40s.yaml ;;
    10_workbench)         ./10_workbench/setup-workbench.sh ;;
    11_model_registry)    ./11_model_registry/setup-model-registry.sh ;;
    12_deploy_model)      ./12_deploy_model/setup-deploy.sh ;;
    13_maas_subscription)
      ./13_maas_subscription/setup-subscription.sh
      ./13_maas_subscription/test-inference.sh ;;
  esac
}

# ---------- 各 stage: 完成驗證 ----------
do_verify() {
  echo "${CYN}--- 驗證 $1 ---${R}"
  case "$1" in
    00_prepare)
      wait_for "已登入 OCP" 1 1 oc whoami || return 1
      wait_for "GPU 節點 Ready" 40 15 sh -c \
        "oc get nodes -l node-role.kubernetes.io/gpu --no-headers 2>/dev/null | grep -w Ready" || return 1 ;;
    01_install_operator)
      local f=0 e
      for e in \
        "cert-manager-operator|cert-manager" "openshift-nfd|nfd" "nvidia-gpu-operator|gpu-operator" \
        "openshift-operators|rhcl-operator" "openshift-lws-operator|leader-worker-set" \
        "openshift-operators|kueue" "openshift-jobset-operator|jobset" \
        "openshift-keda|custom-metrics-autoscaler" "openshift-operators|servicemeshoperator3" \
        "redhat-ods-operator|rhods-operator" "openshift-operators|cluster-observability" \
        "openshift-operators|tempo" "openshift-operators|opentelemetry"; do
        local ns="${e%%|*}" key="${e##*|}"
        if wait_for "CSV $key ($ns)" 60 15 csv_ok "$ns" "$key"; then :; else f=1; fi
      done
      [ "$f" -eq 0 ] ;;
    02_GPU)
      wait_for "ClusterPolicy ready" 1 1 sh -c \
        "[ \"\$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null)\" = ready ]" || return 1
      wait_for "節點有可分配 GPU" 1 1 sh -c \
        "oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' | grep -qE '[1-9]'" ;;
    03_monitoring)
      wait_for "UWM prometheus pods" 12 10 sh -c \
        "oc get pods -n openshift-user-workload-monitoring --no-headers | grep prometheus-user-workload | grep -q Running" || return 1
      wait_for "Grafana deployment Ready" 12 10 sh -c \
        "[ \"\$(oc get deploy grafana -n utilities -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" = 1 ]" || return 1
      echo "  Grafana: https://$(oc get route grafana -n utilities -o jsonpath='{.spec.host}') (admin/admin)" ;;
    04_jobset)
      wait_for "jobset-controller pods Running" 30 10 sh -c \
        "oc get pods -n openshift-jobset-operator --no-headers | grep jobset-controller | grep -q Running" ;;
    05_kuadrant)
      wait_for "Kuadrant CR 存在" 1 1 oc get kuadrant kuadrant -n kuadrant-system || return 1
      wait_for "Authorino deployment Ready" 18 10 sh -c \
        "[ \"\$(oc get deploy authorino -n kuadrant-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" = 1 ]" ;;
    06_rhoai)
      wait_for "GatewayClass Accepted" 1 1 sh -c \
        "[ \"\$(oc get gatewayclass data-science-gateway-class -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null)\" = True ]" || return 1
      wait_for "rhods-dashboard Ready" 30 10 sh -c \
        "oc get pods -n redhat-ods-applications --no-headers | grep rhods-dashboard | grep -q Running" || return 1
      echo "  Dashboard: https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '?')" ;;
    07_llmd)
      wait_for "Gateway openshift-ai-inference Programmed" 30 10 gw_programmed openshift-ai-inference ;;
    08_maas)
      wait_for "Gateway maas-default-gateway Programmed" 30 10 gw_programmed maas-default-gateway || return 1
      wait_for "Postgres Running" 6 10 sh -c \
        "oc get pods -n redhat-ods-applications --no-headers | grep postgresql | grep -q Running" ;;
    09_hardware_profile)
      wait_for "HardwareProfile nvidia-l40s 存在" 1 1 \
        oc get hardwareprofile nvidia-l40s -n redhat-ods-applications ;;
    10_workbench)
      wait_for "Workbench pod Running" 30 10 sh -c \
        "oc get pod -n demo -l app=qwen-workbench --no-headers | grep -q '1/1'" || return 1
      echo "  Workbench: https://$(oc get route qwen-workbench -n demo -o jsonpath='{.spec.host}' 2>/dev/null || echo '?')" ;;
    11_model_registry)
      wait_for "ModelRegistry Available" 12 10 sh -c \
        "[ \"\$(oc get modelregistries.modelregistry.opendatahub.io demo-registry -n rhoai-model-registries -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null)\" = True ]" ;;
    12_deploy_model)
      local m f=0
      for m in qwen3-14b-vllm qwen3-14b-llmd; do
        wait_for "LLMInferenceService $m Ready" 90 10 sh -c \
          "[ \"\$(oc get llminferenceservice $m -n demo -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)\" = True ]" || f=1
      done
      [ "$f" -eq 0 ] ;;
    13_maas_subscription)
      wait_for "MaaSSubscription Active" 6 10 sh -c \
        "[ \"\$(oc get maassubscription demo-subscription -n models-as-a-service -o jsonpath='{.status.phase}' 2>/dev/null)\" = Active ]" || return 1
      echo "  (推理測試已在執行階段通過)" ;;
  esac
}

# ---------- 選單 ----------
current_stage_idx() {
  local i
  for i in "${!STAGES[@]}"; do
    is_done "${STAGES[$i]%%|*}" || { echo "$i"; return; }
  done
  echo "-1"
}

render_menu() {
  clear
  echo "${REV}${BOLD} 此程序僅適用在 RHDP 中的 AWS with OpenShift Open Environment ${R}"
  echo "${REV} 執行需求: bash 3.2+ / oc CLI 4.19+ / jq / curl / python3 | cluster-admin 帳密 ${R}"
  echo "${REV} 叢集需求: OCP 4.19+ (llm-d 建議 4.20) 且可連網拉 image 與 HuggingFace 模型 ${R}"
  echo "${REV} 執行機不需連 GitHub/grafana.com (儀表板離線副本在 00_prepare/source)      ${R}"
  echo ""
  echo "${BOLD} RHOAI 3.4 Demo 安裝流程${R}  (狀態檔: $STATE_FILE)"
  echo " ─────────────────────────────────────────────"
  local cur; cur=$(current_stage_idx)
  local i id desc
  for i in "${!STAGES[@]}"; do
    id="${STAGES[$i]%%|*}"; desc="${STAGES[$i]#*|}"
    if is_done "$id"; then
      printf "     ${REV}${GRN} ✓ %-22s ${R} %s\n" "$id" "$desc"
    elif [ "$i" = "$cur" ]; then
      printf " ${YEL}${BOLD}-->  %-22s${R} %s\n" "$id" "$desc"
    else
      printf "      %-22s %s\n" "$id" "$desc"
    fi
  done
  echo " ─────────────────────────────────────────────"
  if [ "$cur" = "-1" ]; then
    echo " ${GRN}${BOLD}全部完成！${R} 推理端點見 13_maas_subscription/test-inference.sh"
  fi
}

run_stage() {
  local id="$1"
  echo ""
  echo "${BOLD}=============================================${R}"
  echo "${BOLD} 執行 Stage: ${id}${R}"
  echo "${BOLD}=============================================${R}"

  echo "${CYN}--- 前置檢查 ---${R}"
  if ! pre_check "$id"; then
    echo "${RED}>>> 前置檢查未通過，返回選單${R}"; return 1
  fi
  echo "  ${GRN}OK${R} 前置檢查通過"

  echo "${CYN}--- 執行 ---${R}"
  if ! do_exec "$id"; then
    echo "${RED}>>> ${id} 執行失敗，請依上方錯誤訊息排除後重跑${R}"; return 1
  fi

  if do_verify "$id"; then
    mark_done "$id"
    echo "${GRN}${BOLD}>>> ${id} 完成並通過驗證 ✓${R}"
  else
    echo "${RED}>>> ${id} 驗證未通過，未標記完成${R}"; return 1
  fi
}

# ---------- 主迴圈 ----------
while true; do
  render_menu
  cur=$(current_stage_idx)
  echo ""
  echo " [Enter] 執行 --> 的 stage   [r] 重跑指定 stage   [q] 離開"
  printf " 選擇: "
  read -r cmd || exit 0
  case "$cmd" in
    q|Q) exit 0 ;;
    r|R)
      printf " 輸入要重跑的 stage 編號 (00-13): "
      read -r n
      id=""
      for s in "${STAGES[@]}"; do
        case "${s%%|*}" in "$n"*) id="${s%%|*}"; break ;; esac
      done
      if [ -n "$id" ]; then
        grep -vx "$id" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
        run_stage "$id" || true
      else
        echo " 找不到 stage: $n"
      fi
      printf " 按 Enter 返回選單..."; read -r _ ;;
    *)
      if [ "$cur" = "-1" ]; then
        echo " 全部完成，沒有可執行的 stage"; sleep 1; continue
      fi
      run_stage "${STAGES[$cur]%%|*}" || true
      printf " 按 Enter 返回選單..."; read -r _ ;;
  esac
done
