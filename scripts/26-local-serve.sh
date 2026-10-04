#!/usr/bin/env bash
# ============================================================
# アプリ本体（app/main.py）をローカルで起動する
#
#   LOCAL_IMPERSONATE_SA を渡すことで、メタデータサーバーの代わりに
#   「なりすまし」で IDトークンを取得します。
#   Cloud Run にデプロイしたときと同じエンドポイントが全部動きます。
#
#   起動後、別のターミナルで:
#     curl -s localhost:8080/all | jq .
#
#   止めるには Ctrl+C
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd python3

need_state SA_EMAIL "./scripts/10-gcp-setup.sh"
need_state AWS_ROLE_ARN "./scripts/20-aws-setup.sh"
need_state S3_BUCKET "./scripts/20-aws-setup.sh"

VENV="${HANDSON_ROOT}/.venv"

if [[ ! -d "${VENV}" ]]; then
  step "Python 仮想環境を作成（初回のみ）"
  python3 -m venv "${VENV}" || die "venv の作成に失敗しました（python3-venv が必要です）"
  "${VENV}/bin/pip" install --quiet --upgrade pip
  "${VENV}/bin/pip" install --quiet -r "${HANDSON_ROOT}/app/requirements.txt"
  ok "依存ライブラリをインストールしました"
fi

step "ローカルでアプリを起動"
note "AUDIENCE            : ${AUDIENCE}"
note "AWS_ROLE_ARN        : ${AWS_ROLE_ARN}"
note "S3_BUCKET           : ${S3_BUCKET}"
note "LOCAL_IMPERSONATE_SA: ${SA_EMAIL}  ← ローカル専用の迂回路"
note ""
note "別のターミナルで試してください:"
note "  curl -s localhost:8080/        | jq ."
note "  curl -s localhost:8080/all     | jq ."
note "  curl -s localhost:8080/step1/id-token | jq ."
note ""

cd "${HANDSON_ROOT}/app"
AUDIENCE="${AUDIENCE}" \
AWS_ROLE_ARN="${AWS_ROLE_ARN}" \
AWS_REGION="${AWS_REGION}" \
S3_BUCKET="${S3_BUCKET}" \
LOCAL_IMPERSONATE_SA="${SA_EMAIL}" \
PORT="${PORT:-8080}" \
  exec "${VENV}/bin/python" main.py
