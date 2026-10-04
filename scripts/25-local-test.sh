#!/usr/bin/env bash
# ============================================================
# ローカル検証（デプロイ前の動作確認）
#
#   ローカル PC にはメタデータサーバーが無いので、代わりに
#   「サービスアカウントになりすまして IDトークンを発行する」方法を使います。
#   発行されるトークンの sub / aud は Cloud Run 上と同じなので、
#   AWS の信頼ポリシーが正しいかを数秒で検証できます。
#
#   必要な権限: 対象 SA に対する roles/iam.serviceAccountTokenCreator
#              （10-gcp-setup.sh が自分に付与しています）
#
#   前提: 10-gcp-setup.sh と 20-aws-setup.sh が完了していること
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd gcloud
require_cmd aws
require_cmd jq
require_cmd python3

need_state SA_UNIQUE_ID "./scripts/10-gcp-setup.sh"
need_state AWS_ROLE_ARN "./scripts/20-aws-setup.sh"
need_state S3_BUCKET "./scripts/20-aws-setup.sh"

decode_payload() {
  python3 -c '
import base64, json, sys
part = sys.argv[1].split(".")[1]
part += "=" * (-len(part) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(part)), ensure_ascii=False, indent=2))
' "$1"
}

# ------------------------------------------------------------
step "STEP 1 相当: サービスアカウント名義の IDトークンを発行"
note "gcloud auth print-identity-token \\"
note "  --impersonate-service-account=${SA_EMAIL} \\"
note "  --audiences=${AUDIENCE} --include-email"

ID_TOKEN="$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA_EMAIL}" \
  --audiences="${AUDIENCE}" \
  --include-email 2>/dev/null | tr -d '\n')" \
  || die "IDトークンの発行に失敗しました。roles/iam.serviceAccountTokenCreator が付与されているか確認してください。"

[[ -n "${ID_TOKEN}" ]] || die "IDトークンが空です。10-gcp-setup.sh を再実行してください。"
ok "IDトークンを取得しました（${#ID_TOKEN} 文字）"

step "IDトークンの中身（payload）"
PAYLOAD="$(decode_payload "${ID_TOKEN}")"
printf '%s\n' "${PAYLOAD}" | sed 's/^/      /'

TOKEN_SUB="$(printf '%s' "${PAYLOAD}" | jq -r '.sub')"
TOKEN_AUD="$(printf '%s' "${PAYLOAD}" | jq -r '.aud')"

step "AWS 信頼ポリシーの条件と突き合わせる"
if [[ "${TOKEN_SUB}" == "${SA_UNIQUE_ID}" ]]; then
  ok "sub  一致: ${TOKEN_SUB}"
else
  die "sub 不一致: トークン=${TOKEN_SUB} / 期待値=${SA_UNIQUE_ID}"
fi
if [[ "${TOKEN_AUD}" == "${AUDIENCE}" ]]; then
  ok "aud  一致: ${TOKEN_AUD}"
else
  die "aud 不一致: トークン=${TOKEN_AUD} / 期待値=${AUDIENCE}"
fi
note "この 2 つが信頼ポリシーの sub / oaud と一致すれば STS は通ります。"

# ------------------------------------------------------------
step "STEP 2 相当: STS で一時認証情報に交換"
note "aws sts assume-role-with-web-identity --role-arn ${AWS_ROLE_ARN} ..."
note "（この API は AWS の認証情報なしで呼べます）"

STS_JSON="$(aws sts assume-role-with-web-identity \
  --role-arn "${AWS_ROLE_ARN}" \
  --role-session-name "local-test" \
  --web-identity-token "${ID_TOKEN}" \
  --region "${AWS_REGION}" \
  --output json 2>&1)" || {
  printf '%s\n' "${STS_JSON}" | sed 's/^/      /'
  warn "STS が拒否しました。考えられる原因:"
  note "・IAM の変更が伝播していない（十数秒待って再実行）"
  note "・信頼ポリシーの oaud / sub が合っていない（20-aws-setup.sh を再実行）"
  exit 1
}

ACCESS_KEY_ID="$(printf '%s' "${STS_JSON}" | jq -r '.Credentials.AccessKeyId')"
ok "一時認証情報を取得しました"
note "AccessKeyId : ${ACCESS_KEY_ID:0:6}…（${#ACCESS_KEY_ID}文字）"
note "Expiration  : $(printf '%s' "${STS_JSON}" | jq -r '.Credentials.Expiration')"
note "AssumedRole : $(printf '%s' "${STS_JSON}" | jq -r '.AssumedRoleUser.Arn')"
note "Subject     : $(printf '%s' "${STS_JSON}" | jq -r '.SubjectFromWebIdentityToken')"
if [[ "${ACCESS_KEY_ID}" == ASIA* ]]; then
  ok "ASIA で始まる＝一時認証情報です（長期キーは AKIA）"
fi

# ------------------------------------------------------------
# 以降は一時認証情報だけを使う。既存の AWS 認証とは混ざらないよう
# サブシェルの中で環境変数を差し替える。
step "STEP 3・4 相当: 一時認証情報で S3 にアクセス"
(
  export AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${STS_JSON}" | jq -r '.Credentials.SecretAccessKey')"
  export AWS_SESSION_TOKEN="$(printf '%s' "${STS_JSON}" | jq -r '.Credentials.SessionToken')"
  unset AWS_PROFILE

  note "aws sts get-caller-identity →"
  aws sts get-caller-identity --output json | sed 's/^/      /'

  note "aws s3 ls s3://${S3_BUCKET} →"
  aws s3 ls "s3://${S3_BUCKET}" | sed 's/^/      /'

  note "aws s3 cp s3://${S3_BUCKET}/hello.txt - →"
  aws s3 cp "s3://${S3_BUCKET}/hello.txt" - 2>/dev/null | sed 's/^/      /'
)

step "ローカル検証に成功しました"
note "信頼ポリシーと許可ポリシーは正しく設定されています。"
note "Cloud Run にデプロイすれば、同じ流れがそのまま動きます。"
note ""
note "次は: ./scripts/30-deploy.sh"
note "アプリ自体をローカルで動かすなら: ./scripts/26-local-serve.sh"
