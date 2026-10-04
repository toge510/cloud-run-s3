# つまずきポイントとエラー対処

## まず切り分ける: どの段階で失敗したか

```
① IDトークン取得 → ② STS で交換 → ③ S3 アクセス
   Google 側の問題      信頼ポリシー      許可ポリシー
```

エラーメッセージを見れば、どこで止まったかが分かります。

| エラーに出てくる語 | 失敗した段階 | 見るべき場所 |
| --- | --- | --- |
| `metadata`, `compute_engine`, `Connection refused` | ① | Cloud Run のサービスアカウント割り当て |
| `AssumeRoleWithWebIdentity`, `InvalidIdentityToken` | ② | **信頼ポリシー** |
| `GetObject`, `ListBucket`, `NoSuchBucket` | ③ | **許可ポリシー** / バケット名 |

切り分けには個別エンドポイントが便利です。

```bash
./scripts/40-verify.sh 1   # ① だけ試す
./scripts/40-verify.sh 2   # ② まで試す
./scripts/40-verify.sh 4   # ③ まで試す
```

---

## `AccessDenied` — STS が拒否した

```
An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**最も多いエラーです。** 信頼ポリシーの `Condition` に合っていません。
次の順で確認します。

### 1. audience が一致しているか

```bash
# トークンの aud を見る
./scripts/40-verify.sh 1 | jq -r '.payload.aud'

# 信頼ポリシーの oaud を見る
source .state.env
aws iam get-role --role-name "${AWS_ROLE_NAME}" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

**一字一句同じ**である必要があります。よくある差分:

- 末尾のスラッシュ（`https://example.com` と `https://example.com/`）
- `http` と `https`
- 前後の空白や改行

### 2. sub が uniqueId になっているか

```bash
source .state.env
echo "期待値: ${SA_UNIQUE_ID}"
./scripts/40-verify.sh 1 | jq -r '.payload.sub'
```

**メールアドレスを書いていませんか。** `sub` には数字 21 桁を入れます。

### 3. Cloud Run のサービスアカウントが正しいか

```bash
source .state.env
gcloud run services describe "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" \
  --format="value(spec.template.spec.serviceAccountName)"
```

`<プロジェクト番号>-compute@developer.gserviceaccount.com` のような既定の
サービスアカウントが出てきたら、`--service-account` の指定漏れです。
`./scripts/30-deploy.sh` を再実行してください。

### 4. IAM の伝播を待つ

信頼ポリシーを更新した直後は、まだ反映されていないことがあります。
**十数秒待ってから**再実行してください。

---

## `InvalidIdentityToken`

```
An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation
```

トークン自体が AWS 側で検証できていません。

- トークンの期限切れ（`exp` を確認。通常 1 時間）
- トークンが途中で切れている（環境変数経由で渡すときの改行混入など）
- `Principal.Federated` が `accounts.google.com` になっていない

```bash
./scripts/40-verify.sh 1 | jq '.payload.exp, .payload.iat'
```

---

## `AccessDenied` — S3 が拒否した

```
An error occurred (AccessDenied) when calling the ListObjectsV2 operation: Access Denied
```

STS は通ったが、許可ポリシーが足りていません。

```bash
source .state.env
aws iam get-role-policy --role-name "${AWS_ROLE_NAME}" \
  --policy-name "s3-read-${S3_BUCKET}" --output json
```

確認点:

- `s3:ListBucket` に対して **`/*` なし**の ARN があるか
- `s3:GetObject` に対して **`/*` 付き**の ARN があるか
- バケット名が合っているか

この 2 つの ARN の違いは [02-trust-policy.md](02-trust-policy.md) で解説しています。

---

## `NoSuchBucket`

バケットが存在しません。`./scripts/20-aws-setup.sh` を実行してください。
あるいはリージョンが違っています。

```bash
source .state.env
aws s3api get-bucket-location --bucket "${S3_BUCKET}"
```

---

## `503 Service Unavailable` — コンテナが起動していない

アプリのコードまで到達していません。**コンテナの起動そのものが失敗**しています。
ログを見れば原因が分かります。

```bash
source .state.env
gcloud run services logs read "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" --limit 50
```

実際にこのハンズオンの初回デプロイで踏んだ例:

```
ImportError: The requests library is not installed from
please install the requests package to use the requests transport.
[ERROR] Worker failed to boot.
```

`google-auth` は `requests` を**オプショナル依存**として扱うため、
`requirements.txt` に `google-auth` だけ書いても `requests` は入りません。
ローカルでは別経由で入っていて動いてしまうので気づきにくい罠です。

```
google-auth>=2.35
requests>=2.32     ← これが必要
```

`google-auth[requests]` と書いても同じ効果です。

503 のその他の原因:

- `PORT` 環境変数で待ち受けていない（Cloud Run は `PORT` を渡してくる）
- 起動時に必須の環境変数が無く `KeyError` で落ちている
  （`main.py` は `os.environ["AUDIENCE"]` などを import 時に読むため）

---

## Cloud Run の呼び出しで `403 Forbidden`

アプリの中身ではなく、**Cloud Run 自体の呼び出し認証**で弾かれています。
このハンズオンは `--no-allow-unauthenticated` でデプロイしているので、
呼び出しにトークンが必要です。

```bash
source .state.env
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" "${SERVICE_URL}/all"
```

> この `gcloud auth print-identity-token` は **Cloud Run を呼ぶため**のトークンです。
> AWS に渡すトークン（アプリ内部でメタデータサーバーから取得するもの）とは別物です。
> 同じ「ID トークン」という言葉が 2 箇所に出てくるので混同しやすい部分です。

それでも 403 なら、自分に呼び出し権限があるか確認します。

```bash
source .state.env
gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/run.invoker"
```

---

## ローカル検証で `PERMISSION_DENIED` / `IAM_PERMISSION_DENIED`

`25-local-test.sh` や `26-local-serve.sh` で、なりすましが拒否された場合です。

```bash
source .state.env
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project "${GCP_PROJECT_ID}" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator"
```

`iamcredentials.googleapis.com` が有効かも確認します。

```bash
gcloud services enable iamcredentials.googleapis.com --project "${GCP_PROJECT_ID}"
```

権限付与の反映に 1 分ほどかかることがあります。

---

## デプロイが失敗する

### `Cloud Build has not been used in project ... before or it is disabled`

API の有効化が済んでいません。

```bash
./scripts/10-gcp-setup.sh
```

### 課金が有効になっていない

Cloud Run と Cloud Build には課金アカウントの紐付けが必要です。
Google Cloud コンソールの「お支払い」から確認してください。

---

## 気をつけること（セキュリティ）

| 項目 | 理由 |
| --- | --- |
| **一時認証情報もログに出さない** | 漏れれば期限までは使えてしまう。`app/main.py` の `mask()` がこの配慮 |
| **権限は最小に** | 許可ポリシーは必要な操作とバケットだけに絞る |
| **audience は推測されにくい値に** | 必須ではないが、`sub` との二重の壁になる |
| **ロール ARN は秘密ではない** | 漏れても信頼ポリシーがあるので単体では使えない |

---

## どうしても解決しないとき

ローカル検証に戻るのが一番速い切り分けです。
デプロイを挟まずに信頼ポリシーだけを検証できます。

```bash
./scripts/25-local-test.sh
```

- ここで通る → 問題は Cloud Run 側（サービスアカウントの割り当て、環境変数）
- ここで落ちる → 問題は AWS 側（信頼ポリシー、許可ポリシー）
