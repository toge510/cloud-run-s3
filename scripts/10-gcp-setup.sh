#!/usr/bin/env bash
# ============================================================
# STEP 1 ・ Google Cloud
#   Cloud Run が名乗る「身元」=サービスアカウントを作り、
#   AWS 側の信頼ポリシーに書き込む uniqueId（数字のID）を控える。
#
#   ポイント: AWS を触るだけなら、このサービスアカウントに
#            Google Cloud 側の IAM 権限は一切不要。
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd gcloud

[[ -n "${GCP_PROJECT_ID}" ]] || die "GCP_PROJECT_ID が空です。env.sh を確認してください。"

step "設定の確認"
note "プロジェクト      : ${GCP_PROJECT_ID}"
note "リージョン        : ${GCP_REGION}"
note "サービスアカウント: ${SA_EMAIL}"
note "audience          : ${AUDIENCE}"

step "必要な API を有効化（数十秒かかることがあります）"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  --project "${GCP_PROJECT_ID}"
ok "API を有効化しました"

step "サービスアカウントを作成"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project "${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  ok "既に存在します: ${SA_EMAIL}"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="AWS Access (handson)" \
    --project "${GCP_PROJECT_ID}"
  ok "作成しました: ${SA_EMAIL}"
fi

step "uniqueId を取得（AWS 信頼ポリシーの sub に使う値）"
SA_UNIQUE_ID="$(gcloud iam service-accounts describe "${SA_EMAIL}" \
  --project "${GCP_PROJECT_ID}" --format="value(uniqueId)")"
[[ -n "${SA_UNIQUE_ID}" ]] || die "uniqueId の取得に失敗しました"
save_state SA_UNIQUE_ID "${SA_UNIQUE_ID}"
save_state SA_EMAIL "${SA_EMAIL}"

ok "uniqueId = ${SA_UNIQUE_ID}"
note "これはメールアドレスではなく数字の ID です。AWS 側の"
note "accounts.google.com:sub にはこの数字を指定します。"
note "（.state.env に保存したので、次のスクリプトが自動で使います）"

step "ローカル検証用に『なりすまし』権限を自分に付与"
CURRENT_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
if [[ -n "${CURRENT_ACCOUNT}" ]]; then
  gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --project "${GCP_PROJECT_ID}" \
    --member="user:${CURRENT_ACCOUNT}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet >/dev/null
  save_state GCP_USER_ACCOUNT "${CURRENT_ACCOUNT}"
  ok "${CURRENT_ACCOUNT} に roles/iam.serviceAccountTokenCreator を付与しました"
  note "これはサービスアカウント『に』与えた権限ではなく、あなたが"
  note "このサービスアカウント『になりすます』ための権限です。"
  note "デプロイ前にローカルで AWS 接続を検証できるようになります"
  note "（25-local-test.sh）。本番運用では不要なので外して構いません。"
else
  warn "gcloud のアカウントが取得できなかったため、なりすまし権限の付与をスキップしました"
fi

step "完了"
note "次は: ./scripts/20-aws-setup.sh"
