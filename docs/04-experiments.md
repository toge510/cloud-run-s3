# わざと壊して確かめる実験

動いた後にこそ理解が深まります。各実験は**元に戻す手順つき**です。
`25-local-test.sh` を使えばデプロイ不要で数秒で試せるので、ここでは主にそれを使います。

---

## 実験 1: audience を変えると拒否される

**仮説**: `aud` が信頼ポリシーの `oaud` と違えば、STS は拒否する。

```bash
cd cloud-run-s3

# audience を 1 文字だけ変えて（末尾にスラッシュを足す）トークンを取る
source .state.env
BAD_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA_EMAIL}" \
  --audiences="${AUDIENCE}/" \
  --include-email | tr -d '\n')

aws sts assume-role-with-web-identity \
  --role-arn "${AWS_ROLE_ARN}" \
  --role-session-name "experiment-1" \
  --web-identity-token "${BAD_TOKEN}" \
  --region "${AWS_REGION}"
```

**結果**: `AccessDenied` になります（実測で確認済み）。

```
aud = https://cloud-run-s3-handson.example.com/     ← 末尾に / が付いただけ

An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**学び**: 末尾のスラッシュ 1 文字でも拒否されます。`StringEquals` は完全一致です。
「audience の不一致」が最も多いトラブルである理由がこれです。

**元に戻す**: 何も変更していないので不要です。

---

## 実験 2: 別のサービスアカウントでは入れない

**仮説**: `sub` が違えば、同じプロジェクトの別サービスアカウントでも拒否される。

```bash
source .state.env

# 別のサービスアカウントを作る
gcloud iam service-accounts create intruder --project "${GCP_PROJECT_ID}"
INTRUDER="intruder@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "${INTRUDER}" \
  --project "${GCP_PROJECT_ID}" \
  --member="user:$(gcloud config get-value account)" \
  --role="roles/iam.serviceAccountTokenCreator" --quiet

# 正しい audience で、しかし別の SA 名義のトークンを取る
sleep 10
INTRUDER_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="${INTRUDER}" \
  --audiences="${AUDIENCE}" --include-email | tr -d '\n')

aws sts assume-role-with-web-identity \
  --role-arn "${AWS_ROLE_ARN}" \
  --role-session-name "experiment-2" \
  --web-identity-token "${INTRUDER_TOKEN}" \
  --region "${AWS_REGION}"
```

**結果**: `AccessDenied`。audience は正しいのに拒否されます。

**学び**: Google が正しく署名した有効なトークンであっても、`sub` が違えば入れません。
「Google アカウントを持っている」ことは何の権限も意味しない、ということです。

**元に戻す**:

```bash
gcloud iam service-accounts delete "intruder@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --project "${GCP_PROJECT_ID}" --quiet
```

---

## 実験 3: 許可ポリシーの範囲外は操作できない

**仮説**: 信頼ポリシーを通っても、許可ポリシーにない操作は失敗する。

このハンズオンの許可ポリシーは `s3:GetObject` と `s3:ListBucket` だけです。
書き込みを試します。

```bash
source .state.env

# 正規の手順で一時認証情報を取得
ID_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA_EMAIL}" \
  --audiences="${AUDIENCE}" --include-email | tr -d '\n')
STS_JSON=$(aws sts assume-role-with-web-identity \
  --role-arn "${AWS_ROLE_ARN}" --role-session-name "experiment-3" \
  --web-identity-token "${ID_TOKEN}" --region "${AWS_REGION}" --output json)

(
  export AWS_ACCESS_KEY_ID=$(echo "$STS_JSON" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$STS_JSON" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$STS_JSON" | jq -r .Credentials.SessionToken)
  unset AWS_PROFILE

  echo "--- 読み取り（許可されている） ---"
  aws s3 ls "s3://${S3_BUCKET}"

  echo "--- 書き込み（許可されていない） ---"
  echo "test" | aws s3 cp - "s3://${S3_BUCKET}/should-fail.txt"

  echo "--- 他のバケットの一覧（許可されていない） ---"
  aws s3 ls
)
```

**結果**:

- 読み取りは成功
- 書き込みは `AccessDenied`（`s3:PutObject` がない）
- `aws s3 ls`（全バケット一覧）も `AccessDenied`（`s3:ListAllMyBuckets` がない）

**学び**: 信頼ポリシー（誰が入れるか）と許可ポリシー（何ができるか）は完全に別の関門です。
入れたからといって何でもできるわけではありません。

**元に戻す**: 何も書き込めていないので不要です。

---

## 実験 4: 書き込みを許可してみる

**仮説**: 許可ポリシーに `s3:PutObject` を足せば書けるようになる。信頼ポリシーは触らない。

```bash
source .state.env

cat > /tmp/write-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
EOF

aws iam put-role-policy --role-name "${AWS_ROLE_NAME}" \
  --policy-name "s3-read-${S3_BUCKET}" \
  --policy-document file:///tmp/write-policy.json

sleep 15   # 伝播を待つ
```

実験 3 の書き込みコマンドをもう一度試すと、今度は成功します。

**学び**: 権限の増減は許可ポリシーだけで完結します。
「誰が入れるか」の設定（信頼ポリシー）は一度書けば触る必要がありません。

**元に戻す**:

```bash
./scripts/20-aws-setup.sh    # 読み取り専用に戻る
source .state.env
aws s3 rm "s3://${S3_BUCKET}/should-fail.txt"
```

---

## 実験 5: サービスアカウントの割り当てを外す

**仮説**: Cloud Run が既定のサービスアカウントで動くと、`sub` が変わって拒否される。

> これは Cloud Run へのデプロイが必要な実験です（3 分ほど）。

```bash
source .state.env

# 既定のサービスアカウントでデプロイし直す（= 割り当て忘れの再現）
PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT_ID}" --format="value(projectNumber)")
gcloud run services update "${SERVICE_NAME}" \
  --project "${GCP_PROJECT_ID}" --region "${GCP_REGION}" \
  --service-account "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

./scripts/40-verify.sh 1    # sub が変わっているのを確認
./scripts/40-verify.sh 2    # AccessDenied になる
```

**結果**: STEP 1 は成功します（トークンは取れる）が、`sub` が別の値になっており、
STEP 2 で `AccessDenied` になります。

**学び**: ID トークンの `sub` は「Cloud Run に割り当てたサービスアカウント」で決まります。
`--service-account` の指定が認証そのものを左右します。

**元に戻す**:

```bash
./scripts/30-deploy.sh
```

---

## 実験 6: 一時認証情報の寿命を確かめる

```bash
./scripts/40-verify.sh 2 | jq -r '.一時認証情報.Expiration'
```

発行から 1 時間後の時刻が返ります。

`DurationSeconds` で延ばせます（ロールの `MaxSessionDuration` が上限）。
逆に短くすることもできます。

```bash
source .state.env
ID_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA_EMAIL}" \
  --audiences="${AUDIENCE}" --include-email | tr -d '\n')

aws sts assume-role-with-web-identity \
  --role-arn "${AWS_ROLE_ARN}" --role-session-name "experiment-6" \
  --web-identity-token "${ID_TOKEN}" --region "${AWS_REGION}" \
  --duration-seconds 900 \
  --query 'Credentials.Expiration'
```

**学び**: 15 分（最小値）まで短くできます。
長期キーには存在しない「自動的に失効する」という性質が、この方式の価値の中心です。

---

## 実験 7: ID トークンを自分でデコードしてみる

ライブラリを使わず、ただの Base64 デコードで中身が読めることを確認します。

```bash
source .state.env
ID_TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA_EMAIL}" \
  --audiences="${AUDIENCE}" --include-email | tr -d '\n')

# header
echo "${ID_TOKEN}" | cut -d. -f1 | base64 -d 2>/dev/null | jq .
# payload
echo "${ID_TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

**学び**: JWT の中身は**暗号化されていません。誰でも読めます。**
秘密が守られているのではなく、**署名によって改ざんできない**ことが保証の本質です。

だからこそ、

- トークンにパスワードのような秘密情報を入れてはいけない
- トークン自体はログに出さない（期限内なら第三者が使えてしまう）

という注意が成り立ちます。`app/main.py` がトークンを `mask()` して返しているのは
この理由です。

---

## まとめ: 実験から見える設計

| 実験 | 分かること |
| --- | --- |
| 1 | `aud` は完全一致。audience が第一の壁 |
| 2 | `sub` が第二の壁。Google アカウントを持つだけでは無意味 |
| 3 | 信頼ポリシーと許可ポリシーは別の関門 |
| 4 | 権限の調整は許可ポリシーだけで済む |
| 5 | `sub` は Cloud Run の SA 割り当てで決まる |
| 6 | 認証情報は自動的に失効する |
| 7 | 守っているのは秘密性ではなく改ざん耐性 |
