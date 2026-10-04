#!/usr/bin/env bash
# ============================================================
# STEP 3 ・ Google Cloud
#   アプリを Cloud Run にデプロイする。
#   ここで --service-account を指定するのが最大の勘所。
#   指定を忘れると既定のサービスアカウントで動き、
#   sub が一致せず AWS に拒否される。
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd gcloud

need_state SA_EMAIL "./scripts/10-gcp-setup.sh"
need_state AWS_ROLE_ARN "./scripts/20-aws-setup.sh"
need_state S3_BUCKET "./scripts/20-aws-setup.sh"

step "デプロイする内容"
note "サービス名        : ${SERVICE_NAME}"
note "リージョン        : ${GCP_REGION}"
note "サービスアカウント: ${SA_EMAIL}"
note "環境変数 AUDIENCE : ${AUDIENCE}"
note "環境変数 ROLE_ARN : ${AWS_ROLE_ARN}"
note "環境変数 S3_BUCKET: ${S3_BUCKET}"

step "Cloud Run にデプロイ（初回は 2〜4 分かかります）"
gcloud run deploy "${SERVICE_NAME}" \
  --source "${HANDSON_ROOT}/app" \
  --project "${GCP_PROJECT_ID}" \
  --region "${GCP_REGION}" \
  --service-account "${SA_EMAIL}" \
  --no-allow-unauthenticated \
  --set-env-vars "AUDIENCE=${AUDIENCE},AWS_ROLE_ARN=${AWS_ROLE_ARN},AWS_REGION=${AWS_REGION},S3_BUCKET=${S3_BUCKET}" \
  --quiet

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" --format="value(status.url)")"
[[ -n "${SERVICE_URL}" ]] || die "サービス URL の取得に失敗しました"
save_state SERVICE_URL "${SERVICE_URL}"

ok "デプロイ完了: ${SERVICE_URL}"
note "--no-allow-unauthenticated なので、呼び出しには"
note "Google の IDトークンが必要です（40-verify.sh が自動で付けます）。"

step "完了"
note "次は: ./scripts/40-verify.sh"
