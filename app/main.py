"""
Cloud Run から AWS S3 へ「キーレス」でアクセスするデモアプリ。

4 つのステップを、それぞれ個別の URL で確認できるようにしてあります。

  /step1/id-token  : Google のメタデータサーバーから IDトークン（＝社員証）をもらう
  /step2/sts       : そのトークンを AWS STS（＝受付）に渡し、一時認証情報をもらう
  /step3/whoami    : 一時認証情報で「自分が AWS 側で誰として見えているか」を確認する
  /step4/s3-list   : S3 バケットの中身を一覧する
  /step5/s3-read   : S3 のオブジェクトを読む（?key=hello.txt）
  /all             : 上を一気に実行して、流れをまとめて表示する

長期のアクセスキー（AKIA...）はこのコードのどこにも登場しません。
"""

import base64
import csv
import io
import json
import os

import boto3
import google.auth
import google.auth.transport.requests
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request
from google.auth import compute_engine, impersonated_credentials

# ---- 設定（すべて Cloud Run の環境変数から渡す） --------------------------
# AWS 信頼ポリシーの accounts.google.com:oaud と完全一致させる値
AUDIENCE = os.environ["AUDIENCE"]
# 引き受ける IAM ロールの ARN
ROLE_ARN = os.environ["AWS_ROLE_ARN"]
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
S3_BUCKET = os.environ["S3_BUCKET"]
# ローカル検証用の迂回路。Cloud Run 上では空のまま（メタデータサーバーを使う）。
# 値を入れるとサービスアカウントになりすまして IDトークンを発行する。
LOCAL_IMPERSONATE_SA = os.environ.get("LOCAL_IMPERSONATE_SA", "")

app = Flask(__name__)
app.json.ensure_ascii = False  # 日本語をそのまま返す
app.json.sort_keys = False  # 説明 → 値 の順を保つ


# ---- ユーティリティ -------------------------------------------------------
def mask(value: str, keep: int = 6) -> str:
    """秘密情報はログ・レスポンスに出さない。先頭だけ見せて残りは隠す。"""
    if not value:
        return ""
    return f"{value[:keep]}…<{len(value)}文字をマスク>"


def decode_jwt_part(part: str) -> dict:
    """JWT の header / payload（Base64URL）をデコードする。署名検証はしない。

    検証するのは AWS STS 側の仕事。ここは「中身を目で見る」ための処理。
    """
    part += "=" * (-len(part) % 4)  # Base64 のパディングを戻す
    return json.loads(base64.urlsafe_b64decode(part))


# ---- STEP 1: IDトークンを取得（社員証をもらう） ---------------------------
def get_google_id_token() -> str:
    """Cloud Run に割り当てたサービスアカウント名義の IDトークンを取得する。

    鍵ファイルは使わない。Cloud Run の内側からだけ見える
    メタデータサーバー（169.254.169.254）が発行してくれる。
    """
    request_adapter = google.auth.transport.requests.Request()

    if LOCAL_IMPERSONATE_SA:
        # --- ローカル検証用の経路 -------------------------------------
        # ローカル PC にはメタデータサーバーが無いので、代わりに
        # 「自分の権限でサービスアカウントになりすます」方法でトークンを得る。
        # 発行されるトークンの sub / aud は Cloud Run 上と同じになるため、
        # AWS 側の信頼ポリシーをデプロイせずに検証できる。
        # 必要な権限: 対象 SA に対する roles/iam.serviceAccountTokenCreator
        source_credentials, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        target = impersonated_credentials.Credentials(
            source_credentials=source_credentials,
            target_principal=LOCAL_IMPERSONATE_SA,
            target_scopes=["https://www.googleapis.com/auth/cloud-platform"],
        )
        credentials = impersonated_credentials.IDTokenCredentials(
            target_credentials=target,
            target_audience=AUDIENCE,
            include_email=True,
        )
    else:
        # --- Cloud Run 上の本来の経路 ---------------------------------
        credentials = compute_engine.IDTokenCredentials(
            request=request_adapter,
            target_audience=AUDIENCE,  # ← 信頼ポリシーの oaud と一致させる
            use_metadata_identity_endpoint=True,
        )

    credentials.refresh(request_adapter)
    return credentials.token


# ---- STEP 2: STS で一時認証情報に交換（入館証をもらう） -------------------
def assume_role_with_google_token(id_token: str) -> dict:
    """AssumeRoleWithWebIdentity は AWS の認証情報なしで呼べる唯一の入口。

    「IDトークンを見せる」ことが、そのまま認証になっている。
    """
    sts = boto3.client("sts", region_name=AWS_REGION)
    response = sts.assume_role_with_web_identity(
        RoleArn=ROLE_ARN,
        RoleSessionName="cloud-run-session",
        WebIdentityToken=id_token,
    )
    return response


def build_s3_client(credentials: dict):
    """STS が返した 3 点セットで S3 クライアントを作る。"""
    return boto3.client(
        "s3",
        region_name=AWS_REGION,
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )


def get_s3_client():
    """STEP 1 → STEP 2 → S3 クライアント、を一息でやる実用版。"""
    response = assume_role_with_google_token(get_google_id_token())
    return build_s3_client(response["Credentials"])


# ---- エラーを「学べる」形に変換 -------------------------------------------
HINTS = {
    "AccessDenied": (
        "信頼ポリシーの Condition に合致しませんでした。"
        "① accounts.google.com:oaud が環境変数 AUDIENCE と完全一致しているか "
        "② accounts.google.com:sub がサービスアカウントの uniqueId（数字21桁）か "
        "③ Cloud Run に正しいサービスアカウントを割り当てたか、を確認してください。"
    ),
    "InvalidIdentityToken": (
        "IDトークンが AWS 側で検証できませんでした。"
        "audience の値、またはトークンの有効期限を確認してください。"
    ),
    "ExpiredTokenException": "IDトークンまたは一時認証情報の期限が切れています。",
    "NoSuchBucket": f"バケット {S3_BUCKET} が存在しません。20-aws-setup.sh を実行してください。",
}


def error_response(exc: Exception, status: int = 500):
    code = None
    if isinstance(exc, ClientError):
        code = exc.response.get("Error", {}).get("Code")
        status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode", status)
    body = {
        "結果": "失敗",
        "エラーの種類": code or type(exc).__name__,
        "メッセージ": str(exc),
        "ヒント": HINTS.get(code, "詳しくは docs/03-troubleshooting.md を参照してください。"),
        "確認用の設定値": {
            "AUDIENCE": AUDIENCE,
            "AWS_ROLE_ARN": ROLE_ARN,
            "S3_BUCKET": S3_BUCKET,
            "AWS_REGION": AWS_REGION,
        },
    }
    return jsonify(body), status


def guard(fn):
    """各エンドポイントを共通のエラーハンドラで包む。"""

    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except (ClientError, BotoCoreError) as exc:
            return error_response(exc)
        except Exception as exc:  # noqa: BLE001 — ハンズオンなので原因をそのまま見せる
            return error_response(exc)

    wrapper.__name__ = fn.__name__
    return wrapper


# ---- エンドポイント -------------------------------------------------------
@app.get("/")
def index():
    return jsonify(
        {
            "これは": "Cloud Run → AWS S3 キーレス接続ハンズオン",
            "実行モード": (
                f"ローカル検証（{LOCAL_IMPERSONATE_SA} になりすまし）"
                if LOCAL_IMPERSONATE_SA
                else "Cloud Run（メタデータサーバーから IDトークンを取得）"
            ),
            "設定": {
                "AUDIENCE": AUDIENCE,
                "AWS_ROLE_ARN": ROLE_ARN,
                "S3_BUCKET": S3_BUCKET,
                "AWS_REGION": AWS_REGION,
            },
            "試せるURL": {
                "/all": "STEP1〜5 をまとめて実行（まずはこれ）",
                "/step1/id-token": "IDトークン（社員証）の中身を見る",
                "/step2/sts": "STS で一時認証情報（入館証）に交換する",
                "/step3/whoami": "AWS 側から自分がどう見えているか",
                "/step4/s3-list": "バケットの中身を一覧する",
                "/step5/s3-read?key=hello.txt": "オブジェクトを読む",
            },
        }
    )


@app.get("/healthz")
def healthz():
    return "ok", 200


@app.get("/step1/id-token")
@guard
def step1_id_token():
    token = get_google_id_token()
    header_b64, payload_b64, signature_b64 = token.split(".")
    return jsonify(
        {
            "説明": "Google のメタデータサーバーが発行した IDトークン（JWT）です。社員証にあたります。",
            "トークン全体": mask(token, keep=24),
            "header": decode_jwt_part(header_b64),
            "payload": decode_jwt_part(payload_b64),
            "signature": f"<{len(signature_b64)}文字 / Google の秘密鍵による署名>",
            "注目ポイント": {
                "aud": "指定した audience がそのまま入る。AWS の oaud 条件と突き合わせられる。",
                "sub": "サービスアカウントの uniqueId（数字）。AWS の sub 条件と突き合わせられる。",
                "email": "サービスアカウントのメールアドレス。AWS の条件には使わない。",
                "exp": "有効期限（UNIX 時間）。通常 1 時間で切れる。",
            },
        }
    )


@app.get("/step2/sts")
@guard
def step2_sts():
    token = get_google_id_token()
    response = assume_role_with_google_token(token)
    credentials = response["Credentials"]
    return jsonify(
        {
            "説明": "IDトークンと引き換えに、AWS STS が期限つきの一時認証情報を発行しました。",
            "呼んだAPI": "sts:AssumeRoleWithWebIdentity（AWS の認証情報なしで呼べる）",
            "引き受けたロール": response["AssumedRoleUser"],
            "一時認証情報": {
                "AccessKeyId": mask(credentials["AccessKeyId"], keep=6),
                "SecretAccessKey": mask(credentials["SecretAccessKey"], keep=3),
                "SessionToken": mask(credentials["SessionToken"], keep=12),
                "Expiration": credentials["Expiration"].isoformat(),
            },
            "SubjectFromWebIdentityToken": response.get("SubjectFromWebIdentityToken"),
            "Audience": response.get("Audience"),
            "注目ポイント": "AccessKeyId が ASIA で始まる＝一時認証情報。長期キーは AKIA で始まる。",
        }
    )


@app.get("/step3/whoami")
@guard
def step3_whoami():
    response = assume_role_with_google_token(get_google_id_token())
    credentials = response["Credentials"]
    sts = boto3.client(
        "sts",
        region_name=AWS_REGION,
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )
    identity = sts.get_caller_identity()
    identity.pop("ResponseMetadata", None)
    return jsonify(
        {
            "説明": "一時認証情報を使って AWS に『自分は誰か』を尋ねた結果です。",
            "caller_identity": identity,
            "注目ポイント": "Arn が assumed-role/<ロール名>/cloud-run-session になっている＝IAMユーザーではない。",
        }
    )


@app.get("/step4/s3-list")
@guard
def step4_s3_list():
    s3 = get_s3_client()
    response = s3.list_objects_v2(Bucket=S3_BUCKET)
    objects = [
        {
            "key": item["Key"],
            "size": item["Size"],
            "last_modified": item["LastModified"].isoformat(),
        }
        for item in response.get("Contents", [])
    ]
    return jsonify(
        {
            "説明": f"許可ポリシーで s3:ListBucket を許されているので、{S3_BUCKET} の中身が見えます。",
            "bucket": S3_BUCKET,
            "件数": len(objects),
            "objects": objects,
        }
    )


@app.get("/step5/s3-read")
@guard
def step5_s3_read():
    key = request.args.get("key", "hello.txt")
    s3 = get_s3_client()
    body = s3.get_object(Bucket=S3_BUCKET, Key=key)["Body"].read()
    result = {
        "説明": f"s3:GetObject で {key} を読み取りました。",
        "bucket": S3_BUCKET,
        "key": key,
        "バイト数": len(body),
    }
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        result["内容"] = "<バイナリのため省略>"
        return jsonify(result)

    result["内容"] = text
    if key.endswith(".csv"):
        rows = list(csv.reader(io.StringIO(text)))
        if rows:
            # 元ネタのスライドと同じ {"rows": 3, "columns": 4} を再現する
            result["形状"] = {"rows": len(rows) - 1, "columns": len(rows[0])}
    return jsonify(result)


@app.get("/all")
@guard
def all_steps():
    # --- STEP 1 ---
    token = get_google_id_token()
    header_b64, payload_b64, _ = token.split(".")
    payload = decode_jwt_part(payload_b64)

    # --- STEP 2 ---
    sts_response = assume_role_with_google_token(token)
    credentials = sts_response["Credentials"]

    # --- STEP 3 ---
    sts = boto3.client(
        "sts",
        region_name=AWS_REGION,
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
    )
    identity = sts.get_caller_identity()
    identity.pop("ResponseMetadata", None)

    # --- STEP 4 / 5 ---
    s3 = build_s3_client(credentials)
    listing = s3.list_objects_v2(Bucket=S3_BUCKET)
    keys = [item["Key"] for item in listing.get("Contents", [])]

    csv_shape = None
    if "sample.csv" in keys:
        text = s3.get_object(Bucket=S3_BUCKET, Key="sample.csv")["Body"].read().decode("utf-8")
        rows = list(csv.reader(io.StringIO(text)))
        csv_shape = {"rows": len(rows) - 1, "columns": len(rows[0])}

    hello = None
    if "hello.txt" in keys:
        hello = s3.get_object(Bucket=S3_BUCKET, Key="hello.txt")["Body"].read().decode("utf-8")

    return jsonify(
        {
            "step1_IDトークン取得": {
                "どこで": "Google Cloud（Cloud Run 内のメタデータサーバー）",
                "aud": payload.get("aud"),
                "sub": payload.get("sub"),
                "email": payload.get("email"),
                "exp": payload.get("exp"),
                "header": decode_jwt_part(header_b64),
            },
            "step2_STSで交換": {
                "どこで": "AWS STS",
                "引き受けたロール": sts_response["AssumedRoleUser"]["Arn"],
                "AccessKeyId": mask(credentials["AccessKeyId"], keep=6),
                "Expiration": credentials["Expiration"].isoformat(),
            },
            "step3_AWSから見た自分": identity,
            "step4_S3一覧": {"bucket": S3_BUCKET, "keys": keys},
            "step5_S3読み取り": {"hello.txt": hello, "sample.csv の形状": csv_shape},
            "結論": "長期アクセスキーを一切保存せずに S3 を読めました。",
        }
    )


if __name__ == "__main__":
    # ローカル実行用（メタデータサーバーが無いので step1 は失敗します）
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=True)
