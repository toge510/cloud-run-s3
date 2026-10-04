#!/usr/bin/env bash
# ============================================================
# ハンズオン共通設定
#   自分の環境に合わせて書き換えてから各スクリプトを実行します。
#   変更が必要なのは基本的に「AUDIENCE」以外は無し（そのままでも動きます）。
# ============================================================

# ---- Google Cloud -----------------------------------------
# 使う GCP プロジェクト（未指定なら gcloud の現在の設定を使う）
export GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
# Cloud Run をデプロイするリージョン
export GCP_REGION="asia-northeast1"
# これから作るサービスアカウント名（= Cloud Run の「身元」）
export SA_NAME="aws-access"
# Cloud Run のサービス名
export SERVICE_NAME="s3-keyless"

# ---- AWS ---------------------------------------------------
export AWS_REGION="ap-northeast-1"
export AWS_DEFAULT_REGION="${AWS_REGION}"
# これから作る IAM ロール名（= AWS 側の「入館証の種類」）
export AWS_ROLE_NAME="cloud-run-s3-reader"
# 空なら 20-aws-setup.sh が自動で取得して .state.env に保存します
export AWS_ACCOUNT_ID=""
# 空なら cloud-run-s3-handson-<AWS_ACCOUNT_ID> を使います
export S3_BUCKET=""

# ---- フェデレーション（最重要） -----------------------------
# IDトークンを取るときの audience と、AWS 信頼ポリシーの
# accounts.google.com:oaud に指定する値。**両者は一字一句同じ**にします。
# 中身は任意の文字列で構いません（URL 形式にするのが慣習）。
export AUDIENCE="https://cloud-run-s3-handson.example.com"
