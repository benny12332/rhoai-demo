#!/usr/bin/env bash
# =============================================================
# RHOAI Demo - fix.sh
# 修復 RHCL 被自動升級的問題:
#   從 openshift-operators 移除 RHCL 主 operator 與其子 operator
#   (Authorino / Limitador / DNS) 的 Subscription 與 CSV,
#   再重跑 01_install_operator/install.sh
#   讓 RHCL 重裝進專屬 namespace (rhcl-operator) 並鎖定 v1.3.4
# 可重複執行 (沒有殘留時各步驟自動跳過)
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

NS=openshift-operators
PATTERN='rhcl|authorino|limitador|dns-operator'

oc whoami >/dev/null 2>&1 || { echo "!!! 尚未登入 OCP，先跑 00_prepare/prepare.sh"; exit 1; }

echo "=== 1. 檢查 ${NS} 中 RHCL 相關殘留 ==="
FOUND=$(oc get subscription,csv -n $NS 2>/dev/null | grep -E "$PATTERN" || true)
if [ -z "$FOUND" ]; then
  echo ">>> 沒有殘留，直接進行重裝"
else
  echo "$FOUND"

  echo ""
  echo "=== 2. 刪除 Subscription ==="
  SUBS=$(oc get subscription -n $NS -o name 2>/dev/null | grep -E "$PATTERN" | sed 's|.*/||' || true)
  if [ -n "$SUBS" ]; then
    # shellcheck disable=SC2086
    oc delete subscription -n $NS $SUBS
  else
    echo ">>> 無相關 Subscription (子 operator 通常只有 CSV，正常)"
  fi

  echo ""
  echo "=== 3. 刪除 CSV (主 + 子 operator) ==="
  CSVS=$(oc get csv -n $NS -o name 2>/dev/null | grep -E "$PATTERN" | sed 's|.*/||' || true)
  if [ -n "$CSVS" ]; then
    # shellcheck disable=SC2086
    oc delete csv -n $NS $CSVS
  else
    echo ">>> 無相關 CSV"
  fi

  echo ""
  echo "=== 4. 確認清理結果 ==="
  LEFT=$(oc get subscription,csv -n $NS 2>/dev/null | grep -E "$PATTERN" || true)
  if [ -n "$LEFT" ]; then
    echo "!!! 仍有殘留，請手動處理:"; echo "$LEFT"; exit 1
  fi
  echo ">>> ${NS} 已清乾淨"
fi

echo ""
echo "=== 5. 重跑 operator 安裝 (RHCL -> ns rhcl-operator, 鎖定 v1.3.4) ==="
./01_install_operator/install.sh

echo ""
echo "=== 6. 驗證 ==="
echo "--- rhcl-operator namespace 中的 CSV:"
oc get csv -n rhcl-operator 2>/dev/null | grep -E "$PATTERN" || { echo "!!! rhcl-operator ns 沒有 RHCL CSV"; exit 1; }

VER=$(oc get csv -n rhcl-operator -o name 2>/dev/null | grep 'rhcl-operator' | sed 's|.*/||')
if [ "$VER" = "rhcl-operator.v1.3.4" ]; then
  echo ">>> OK: RHCL 鎖定在 v1.3.4"
else
  echo "!!! RHCL 版本為 ${VER:-未安裝}，非預期的 v1.3.4"
  exit 1
fi

# 提醒: Kuadrant CR 在 kuadrant-system, operator 重裝後檢查其狀態
if oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1; then
  echo "--- Kuadrant CR 狀態 (operator 重裝後應自行 reconcile):"
  oc get kuadrant kuadrant -n kuadrant-system
  echo "    若長時間未 Ready 可重跑 05_kuadrant/setup-kuadrant.sh"
fi

echo ""
echo ">>> fix.sh 完成"
