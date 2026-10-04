#!/usr/bin/env bash
# ============================================================
# STEP 4 ・ 動作確認
#   4 ステップを 1 つずつ叩いて、何が起きているかを目で追う。
#
#   使い方:
#     ./scripts/40-verify.sh          # 全ステップを順番に確認
#     ./scripts/40-verify.sh all      # /all だけを叩く
#     ./scripts/40-verify.sh 1        # STEP 1 だけを叩く
# ============================================================
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd gcloud
require_cmd curl
require_cmd jq

need_state SERVICE_URL "./scripts/30-deploy.sh"

# Cloud Run 自体の呼び出し認証に使うトークン（AWS とは無関係）
CALLER_TOKEN="$(gcloud auth print-identity-token)"

call() {
  local path="$1" title="$2"
  step "${title}"
  note "GET ${path}"
  local http_code body tmp
  tmp="$(mktemp)"
  http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
    -H "Authorization: Bearer ${CALLER_TOKEN}" \
    "${SERVICE_URL}${path}")"
  body="$(cat "${tmp}")"
  rm -f "${tmp}"

  if [[ "${http_code}" == "200" ]]; then
    printf '%s\n' "${body}" | jq .
    ok "HTTP ${http_code}"
  else
    printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
    warn "HTTP ${http_code} — docs/03-troubleshooting.md を参照してください"
  fi
}

target="${1:-full}"

case "${target}" in
  all)
    call "/all" "4 ステップをまとめて実行"
    ;;
  1) call "/step1/id-token" "STEP 1: IDトークン（社員証）の中身" ;;
  2) call "/step2/sts" "STEP 2: STS で一時認証情報（入館証）に交換" ;;
  3) call "/step3/whoami" "STEP 3: AWS から見た自分の正体" ;;
  4) call "/step4/s3-list" "STEP 4: S3 バケットの一覧" ;;
  5) call "/step5/s3-read?key=sample.csv" "STEP 5: S3 オブジェクトの読み取り" ;;
  full)
    call "/" "アプリの設定を確認"
    call "/step1/id-token" "STEP 1: IDトークン（社員証）の中身"
    note ""
    note "↑ payload の aud が env.sh の AUDIENCE と一致し、"
    note "  sub が ${SA_UNIQUE_ID:-<uniqueId>} になっていることを確認してください。"
    call "/step2/sts" "STEP 2: STS で一時認証情報（入館証）に交換"
    note ""
    note "↑ AccessKeyId が ASIA で始まる＝一時認証情報。長期キーなら AKIA。"
    call "/step3/whoami" "STEP 3: AWS から見た自分の正体"
    call "/step4/s3-list" "STEP 4: S3 バケットの一覧"
    call "/step5/s3-read?key=sample.csv" "STEP 5: S3 オブジェクトの読み取り"
    note ""
    note "↑ 形状が {\"rows\": 3, \"columns\": 4} になれば、元ネタの記事と同じ結果です。"
    step "すべて完了"
    note "長期アクセスキーを 1 つも作らずに S3 を読めました。"
    note "次は docs/04-experiments.md の実験で、仕組みを壊して確かめてみてください。"
    ;;
  *)
    die "使い方: $0 [full|all|1|2|3|4|5]"
    ;;
esac
