# 実際に動かしたときの出力（実測ログ）

このハンズオンは実環境（GCP プロジェクト `<PROJECT_ID>` / AWS アカウント `<AWS_ACCOUNT_ID>`）で
通して実行・検証済みです。自分の実行結果と見比べるための記録です。

---

## STEP 1 — Google Cloud: サービスアカウント作成

```
▶ 必要な API を有効化（数十秒かかることがあります）
  ✓ API を有効化しました

▶ サービスアカウントを作成
  ✓ 作成しました: aws-access@<PROJECT_ID>.iam.gserviceaccount.com

▶ uniqueId を取得（AWS 信頼ポリシーの sub に使う値）
  ✓ uniqueId = <SA_UNIQUE_ID>

▶ ローカル検証用に『なりすまし』権限を自分に付与
  ✓ <your-account>@example.com に roles/iam.serviceAccountTokenCreator を付与しました
```

**ここで覚えること**: `<SA_UNIQUE_ID>` が以降すべての鍵になります。
メールアドレスではなくこの数字です。

> 権限を付与した直後は反映されておらず、`25-local-test.sh` が
> `PERMISSION_DENIED: Permission 'iam.serviceAccounts.getAccessToken' denied`
> で失敗しました。**1 分ほど待つと通りました。** IAM の伝播待ちはよくあります。

---

## STEP 2 — AWS: IAM ロール作成

```
▶ 設定の確認
    AWS アカウント  : <AWS_ACCOUNT_ID>
    バケット        : cloud-run-s3-handson-<AWS_ACCOUNT_ID>
    sub に入れる値  : <SA_UNIQUE_ID>  ← Google の uniqueId
    oaud に入れる値 : https://cloud-run-s3-handson.example.com

▶ ① S3 バケットを作成
  ✓ 作成しました: s3://cloud-run-s3-handson-<AWS_ACCOUNT_ID>

▶ ② IAM ロールを作成（信頼ポリシー）
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": { "Federated": "accounts.google.com" },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
              "StringEquals": {
                "accounts.google.com:oaud": "https://cloud-run-s3-handson.example.com",
                "accounts.google.com:sub": "<SA_UNIQUE_ID>"
              }
            }
          }
        ]
      }
  ✓ ロール ARN = arn:aws:iam::<AWS_ACCOUNT_ID>:role/cloud-run-s3-reader
```

---

## STEP 2.5 — ローカル検証（デプロイ前）

```
▶ STEP 1 相当: サービスアカウント名義の IDトークンを発行
  ✓ IDトークンを取得しました（792 文字）

▶ IDトークンの中身（payload）
      {
        "aud": "https://cloud-run-s3-handson.example.com",
        "azp": "<SA_UNIQUE_ID>",
        "email": "aws-access@<PROJECT_ID>.iam.gserviceaccount.com",
        "email_verified": true,
        "exp": 1791115066,
        "iat": 1791111466,
        "iss": "https://accounts.google.com",
        "sub": "<SA_UNIQUE_ID>"
      }

▶ AWS 信頼ポリシーの条件と突き合わせる
  ✓ sub  一致: <SA_UNIQUE_ID>
  ✓ aud  一致: https://cloud-run-s3-handson.example.com

▶ STEP 2 相当: STS で一時認証情報に交換
  ✓ 一時認証情報を取得しました
    AccessKeyId : ASIA…（20文字）
    Expiration  : 2026-10-04T11:57:47+00:00
    AssumedRole : arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/cloud-run-s3-reader/local-test
    Subject     : <SA_UNIQUE_ID>
  ✓ ASIA で始まる＝一時認証情報です（長期キーは AKIA）

▶ STEP 3・4 相当: 一時認証情報で S3 にアクセス
      {
          "UserId": "AROA<ROLE_ID>:local-test",
          "Account": "<AWS_ACCOUNT_ID>",
          "Arn": "arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/cloud-run-s3-reader/local-test"
      }
      2026-10-04 19:57:14        198 hello.txt
      2026-10-04 19:57:15         94 sample.csv
      このファイルは S3 に置かれています。
      Cloud Run は長期アクセスキーを一切持たず、
      Google が発行した IDトークンだけでこの内容を読み取りました。

▶ ローカル検証に成功しました
```

**ここで覚えること**: `aud` と `sub` が一致していれば STS は通ります。
`iat` と `exp` の差は 3600 秒（1 時間）です。

---

## STEP 3 — デプロイ（1 回目は失敗）

```
▶ Cloud Run にデプロイ（初回は 2〜4 分かかります）
Creating Container Repository...done
Uploading sources...done
Building Container...done
Creating Revision...done
  ✓ デプロイ完了: https://s3-keyless-<hash>-an.a.run.app
```

デプロイ自体は成功しましたが、動作確認で全エンドポイントが `503` になりました。

```
▶ アプリの設定を確認
    GET /
Service Unavailable
  ! HTTP 503
```

ログを見ると原因が分かりました。

```
ImportError: The requests library is not installed from
please install the requests package to use the requests transport.
[ERROR] Worker failed to boot.
```

`google-auth` は `requests` をオプショナル依存にしているため、
`requirements.txt` に明示的に追加する必要がありました。

```diff
 google-auth>=2.35
+requests>=2.32
 boto3>=1.35
```

修正後に再デプロイして解決（リビジョン `s3-keyless-00002-jh9`）。

> **これも教材です。** 503 はアプリに到達する前の失敗なので、
> 認証周りを疑う前にまずログを見る、という切り分けの練習になります。

---

## STEP 4 — 動作確認（成功）

### `/` — 実行モードの確認

```json
{
  "これは": "Cloud Run → AWS S3 キーレス接続ハンズオン",
  "実行モード": "Cloud Run（メタデータサーバーから IDトークンを取得）",
  "設定": {
    "AUDIENCE": "https://cloud-run-s3-handson.example.com",
    "AWS_ROLE_ARN": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/cloud-run-s3-reader",
    "S3_BUCKET": "cloud-run-s3-handson-<AWS_ACCOUNT_ID>",
    "AWS_REGION": "ap-northeast-1"
  }
}
```

### `/step1/id-token` — 社員証の中身

```json
{
  "トークン全体": "eyJhbGciOiJSUzI1NiIsImtp…<792文字をマスク>",
  "header": {
    "alg": "RS256",
    "kid": "943a3a5d7d919625a454e489b75c29adab57acba",
    "typ": "JWT"
  },
  "payload": {
    "aud": "https://cloud-run-s3-handson.example.com",
    "azp": "<SA_UNIQUE_ID>",
    "email": "aws-access@<PROJECT_ID>.iam.gserviceaccount.com",
    "email_verified": true,
    "exp": 1791115241,
    "iat": 1791111641,
    "iss": "https://accounts.google.com",
    "sub": "<SA_UNIQUE_ID>"
  },
  "signature": "<342文字 / Google の秘密鍵による署名>"
}
```

**注目**: ローカルのなりすましで取ったトークンと `sub` / `aud` が完全に同じです。
だからローカル検証が成立します。`kid` は Google が署名に使った鍵の ID で、
AWS STS はこれを使って公開鍵を特定し、署名を検証します。

### `/step2/sts` — 入館証をもらう

```json
{
  "呼んだAPI": "sts:AssumeRoleWithWebIdentity（AWS の認証情報なしで呼べる）",
  "引き受けたロール": {
    "AssumedRoleId": "AROA<ROLE_ID>:cloud-run-session",
    "Arn": "arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/cloud-run-s3-reader/cloud-run-session"
  },
  "一時認証情報": {
    "AccessKeyId": "ASIA…<20文字をマスク>",
    "SecretAccessKey": "<マスク>",
    "SessionToken": "<マスク>",
    "Expiration": "2026-10-04T12:00:41+00:00"
  },
  "SubjectFromWebIdentityToken": "<SA_UNIQUE_ID>",
  "Audience": "<SA_UNIQUE_ID>"
}
```

**注目**: `Audience` が `aud`（URL）ではなく **`azp`（uniqueId）** を返しています。
これが `accounts.google.com:aud` ではなく `oaud` を使う理由です
（詳細は [02-trust-policy.md](02-trust-policy.md)）。

### `/step3/whoami` — AWS から見た自分

```json
{
  "caller_identity": {
    "UserId": "AROA<ROLE_ID>:cloud-run-session",
    "Account": "<AWS_ACCOUNT_ID>",
    "Arn": "arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/cloud-run-s3-reader/cloud-run-session"
  }
}
```

**注目**: `assumed-role/<ロール名>/<セッション名>` の形。IAM ユーザーは存在しません。
セッション名はコードの `RoleSessionName="cloud-run-session"` がそのまま出ています
（CloudTrail でこの名前で追跡できます）。

### `/step4/s3-list` — バケットの一覧

```json
{
  "bucket": "cloud-run-s3-handson-<AWS_ACCOUNT_ID>",
  "件数": 2,
  "objects": [
    { "key": "hello.txt",  "size": 198, "last_modified": "2026-10-04T10:57:14+00:00" },
    { "key": "sample.csv", "size": 94,  "last_modified": "2026-10-04T10:57:15+00:00" }
  ]
}
```

### `/step5/s3-read?key=sample.csv` — オブジェクトを読む

```json
{
  "key": "sample.csv",
  "バイト数": 94,
  "内容": "id,name,region,value\n1,alpha,ap-northeast-1,100\n2,bravo,us-east-1,200\n3,charlie,eu-west-1,300\n",
  "形状": { "rows": 3, "columns": 4 }
}
```

**元ネタの記事の結果 `{"columns":4,"rows":3}` と一致しました。**

---

## つまずいた箇所のまとめ（実測ベース）

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `PERMISSION_DENIED: iam.serviceAccounts.getAccessToken` | 権限付与直後の伝播待ち | 1 分待って再実行 |
| 全エンドポイントが `503` | `requests` が未インストール | `requirements.txt` に追加 |

認証そのもの（信頼ポリシー・許可ポリシー）は一度も失敗しませんでした。
ローカル検証（`25-local-test.sh`）でデプロイ前に確認できていたからです。
**この順番で進めるのが、このハンズオンの要点でもあります。**
