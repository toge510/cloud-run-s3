#!/usr/bin/env bash
# 各スクリプトが最初に source する共通処理。直接実行する必要はありません。
set -euo pipefail

HANDSON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${HANDSON_ROOT}/env.sh"

# 前のステップが保存した値（uniqueId / ロール ARN / Cloud Run URL など）を読み込む。
# env.sh より後に読むので、こちらの値が優先される。
STATE_FILE="${HANDSON_ROOT}/.state.env"
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

# サービスアカウントのメールアドレスは名前から決まる
SA_EMAIL="${SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m';  C_DIM=$'\033[2m';      C_OFF=$'\033[0m'

step() { printf '\n%s▶ %s%s\n' "${C_BLUE}" "$*" "${C_OFF}"; }
ok()   { printf '%s  ✓ %s%s\n' "${C_GREEN}" "$*" "${C_OFF}"; }
note() { printf '%s    %s%s\n' "${C_DIM}" "$*" "${C_OFF}"; }
warn() { printf '%s  ! %s%s\n' "${C_YELLOW}" "$*" "${C_OFF}"; }
die()  { printf '%s  ✗ %s%s\n' "${C_RED}" "$*" "${C_OFF}" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。インストールしてください。"
}

# key=value を .state.env に保存し、同時に現在のシェルにも export する
save_state() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "${STATE_FILE}" ]]; then
    grep -v "^export ${key}=" "${STATE_FILE}" > "${tmp}" || true
  fi
  printf 'export %s="%s"\n' "${key}" "${val}" >> "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
  export "${key}=${val}"
}

# AWS アカウント ID とバケット名を確定させる（AWS 認証が必要なスクリプトだけで呼ぶ）
resolve_aws() {
  if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
      || die "AWS の認証が切れています。'aws login'（SSO なら 'aws sso login'）を実行してください。"
    save_state AWS_ACCOUNT_ID "${AWS_ACCOUNT_ID}"
  fi
  if [[ -z "${S3_BUCKET:-}" ]]; then
    save_state S3_BUCKET "cloud-run-s3-handson-${AWS_ACCOUNT_ID}"
  fi
  AWS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_ROLE_NAME}"
}

# 必須の state が無いときに分かりやすく止める
need_state() {
  local key="$1" hint="$2"
  [[ -n "${!key:-}" ]] || die "${key} が未設定です。先に ${hint} を実行してください。"
}
