#!/usr/bin/env bash
# ============================================================
# 後片付け
#   ハンズオンで作ったものを全部消します。
#   消すもの:
#     - Cloud Run サービス
#     - Google のサービスアカウント
#     - S3 バケット（中身ごと）
#     - IAM ロールとインラインポリシー
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

step "削除対象"
note "Cloud Run        : ${SERVICE_NAME} (${GCP_REGION} / ${GCP_PROJECT_ID})"
note "サービスアカウント: ${SA_EMAIL}"
note "S3 バケット      : ${S3_BUCKET:-<未作成>}"
note "IAM ロール       : ${AWS_ROLE_NAME}"
printf '\n本当に削除しますか？ [y/N]: '
read -r answer
[[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "中止しました"

step "Cloud Run サービスを削除"
gcloud run services delete "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" --quiet 2>/dev/null \
  && ok "削除しました" || warn "存在しないかすでに削除済み"

step "サービスアカウントを削除"
gcloud iam service-accounts delete "${SA_EMAIL}" \
  --project "${GCP_PROJECT_ID}" --quiet 2>/dev/null \
  && ok "削除しました" || warn "存在しないかすでに削除済み"

if [[ -n "${S3_BUCKET:-}" ]]; then
  step "S3 バケットを中身ごと削除"
  aws s3 rm "s3://${S3_BUCKET}" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" 2>/dev/null \
    && ok "削除しました" || warn "存在しないかすでに削除済み"
fi

step "IAM ロールを削除"
if aws iam get-role --role-name "${AWS_ROLE_NAME}" >/dev/null 2>&1; then
  # インラインポリシーを先に剥がさないとロールは消せない
  for policy in $(aws iam list-role-policies --role-name "${AWS_ROLE_NAME}" \
      --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "${AWS_ROLE_NAME}" --policy-name "${policy}"
    note "インラインポリシーを削除: ${policy}"
  done
  aws iam delete-role --role-name "${AWS_ROLE_NAME}"
  ok "削除しました"
else
  warn "存在しないかすでに削除済み"
fi

step "ローカルの作業ファイルを削除"
rm -f "${STATE_FILE}"
rm -rf "${HANDSON_ROOT}/.build"
ok ".state.env と .build を削除しました"

step "完了"
note "Artifact Registry に残ったコンテナイメージは別途課金対象です。"
note "不要なら削除してください:"
note "  gcloud artifacts repositories list --project ${GCP_PROJECT_ID}"
