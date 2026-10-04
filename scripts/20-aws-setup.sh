#!/usr/bin/env bash
# ============================================================
# STEP 2 ・ AWS
#   ① S3 バケットを作ってサンプルデータを置く
#   ② IAM ロールを作る
#        - 信頼ポリシー : 誰が入れるか（Google の特定サービスアカウントだけ）
#        - 許可ポリシー : 入って何ができるか（このバケットの読み取りだけ）
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd aws
require_cmd python3

need_state SA_UNIQUE_ID "./scripts/10-gcp-setup.sh"
resolve_aws

BUILD_DIR="${HANDSON_ROOT}/.build"
mkdir -p "${BUILD_DIR}"

# テンプレートの ${VAR} を環境変数で置換する
render() {
  python3 - "$1" "$2" <<'PY'
import os, string, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    template = string.Template(f.read())
with open(dst, "w", encoding="utf-8") as f:
    f.write(template.substitute(os.environ))
PY
}

step "設定の確認"
note "AWS アカウント  : ${AWS_ACCOUNT_ID}"
note "リージョン      : ${AWS_REGION}"
note "バケット        : ${S3_BUCKET}"
note "ロール          : ${AWS_ROLE_NAME}"
note "sub に入れる値  : ${SA_UNIQUE_ID}  ← Google の uniqueId"
note "oaud に入れる値 : ${AUDIENCE}      ← env.sh の AUDIENCE"

# ------------------------------------------------------------
step "① S3 バケットを作成"
if aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
  ok "既に存在します: s3://${S3_BUCKET}"
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${S3_BUCKET}" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  ok "作成しました: s3://${S3_BUCKET}"
fi

step "サンプルデータをアップロード"
aws s3 cp "${HANDSON_ROOT}/aws/sample-data/hello.txt"  "s3://${S3_BUCKET}/hello.txt"  >/dev/null
aws s3 cp "${HANDSON_ROOT}/aws/sample-data/sample.csv" "s3://${S3_BUCKET}/sample.csv" >/dev/null
ok "hello.txt と sample.csv を置きました（sample.csv は 3 行 × 4 列）"

# ------------------------------------------------------------
step "② IAM ロールを作成（信頼ポリシー）"
render "${HANDSON_ROOT}/aws/trust-policy.template.json" "${BUILD_DIR}/trust-policy.json"
note "生成した信頼ポリシー:"
sed 's/^/      /' "${BUILD_DIR}/trust-policy.json"

if aws iam get-role --role-name "${AWS_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${AWS_ROLE_NAME}" \
    --policy-document "file://${BUILD_DIR}/trust-policy.json"
  ok "既存ロールの信頼ポリシーを更新しました: ${AWS_ROLE_NAME}"
else
  aws iam create-role --role-name "${AWS_ROLE_NAME}" \
    --description "Cloud Run keyless access to S3 (handson)" \
    --assume-role-policy-document "file://${BUILD_DIR}/trust-policy.json" >/dev/null
  ok "作成しました: ${AWS_ROLE_NAME}"
fi

step "許可ポリシーを付与（最小権限）"
render "${HANDSON_ROOT}/aws/permission-policy.template.json" "${BUILD_DIR}/permission-policy.json"
aws iam put-role-policy --role-name "${AWS_ROLE_NAME}" \
  --policy-name "s3-read-${S3_BUCKET}" \
  --policy-document "file://${BUILD_DIR}/permission-policy.json"
ok "s3:GetObject と s3:ListBucket を ${S3_BUCKET} に限って許可しました"

save_state AWS_ROLE_ARN "${AWS_ROLE_ARN}"
ok "ロール ARN = ${AWS_ROLE_ARN}"

step "完了"
warn "IAM の変更が全リージョンに伝播するまで数秒〜十数秒かかります。"
note "次は: ./scripts/30-deploy.sh"
