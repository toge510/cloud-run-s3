# 信頼ポリシーを 1 行ずつ読む

この仕組みの核心は信頼ポリシーです。ここが書ければ 9 割終わりです。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGoogleServiceAccountToAssumeThisRole",
      "Effect": "Allow",
      "Principal": {
        "Federated": "accounts.google.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "accounts.google.com:oaud": "https://cloud-run-s3-handson.example.com",
          "accounts.google.com:sub": "123456789012345678901"
        }
      }
    }
  ]
}
```

---

## `"Version": "2012-10-17"`

IAM ポリシー言語のバージョン。**日付は固定値**で、今日の日付ではありません。
これ以外の値を書くと `Condition` などが使えなくなります。常にこの値です。

## `"Effect": "Allow"`

このステートメントが許可であることを示します。

## `"Principal": { "Federated": "accounts.google.com" }`

**「Google が発行した ID トークンを受け入れる」という宣言です。**

- `Federated` は「外部の身元プロバイダ（IdP）経由で来る相手」を指します
- 値 `accounts.google.com` は Google の OpenID Connect 発行者 (issuer) を表す固定文字列です
- この行がないと、STS は「どこの IdP を信じればいいのか」が分かりません

> ここに書けるのは AWS が組み込みで知っている IdP（`accounts.google.com`,
> `www.amazon.com`, `graph.facebook.com`, `cognito-identity.amazonaws.com`）か、
> 自分で登録した OIDC プロバイダの ARN です。
> Google は組み込みなので、**IAM に IdP を登録する作業が不要**です。
> これが Google → AWS のフェデレーションが手軽な理由です。

## `"Action": "sts:AssumeRoleWithWebIdentity"`

許可する API を 1 つに絞っています。

`sts:AssumeRole`（AWS 内部からロールを引き受ける通常の API）ではなく、
**Web Identity 版**であることが重要です。この API だけが「AWS の認証情報なしで、
外部 IdP のトークンを持って呼べる」入口になっています。

## `"Condition"` — ここが本番

`Principal` と `Action` だけだと「**Google アカウントを持っている世界中の誰でも**
このロールを引き受けられる」状態になります。危険です。

そこで条件で絞り込みます。

### `"accounts.google.com:sub": "123456789012345678901"`

**誰が来たのか**を特定します。

- 値は Google サービスアカウントの **uniqueId**（数字 21 桁）
- **メールアドレスではありません。** ここが最大のつまずきポイントです
- 取得方法:

```bash
gcloud iam service-accounts describe aws-access@<PROJECT_ID>.iam.gserviceaccount.com \
  --format="value(uniqueId)"
```

なぜメールではなく数字なのか——メールアドレスは削除して同名で再作成できてしまいますが、
uniqueId は再作成すると**別の値**になります。つまり
「削除された SA と同名の SA を作って成り代わる」攻撃を防げます。

複数のサービスアカウントを許可したいときは配列にできます。

```json
"accounts.google.com:sub": ["123456789012345678901", "987654321098765432109"]
```

`StringEquals` で配列を書くと「どれかに一致すれば OK」(OR) の意味になります。

### `"accounts.google.com:oaud": "https://cloud-run-s3-handson.example.com"`

**どこ向けに発行されたトークンか**を確認します。

- 値は ID トークンを取得するときに指定した `audience` と**一字一句同じ**にします
- 末尾のスラッシュ 1 つの違いでも拒否されます
- 中身は任意の文字列です。URL でなくても動きますが、慣習として URL 形式にします
  - 元ネタの記事では Cloud Run のサービス URL を使っています。その場合は
    一度デプロイして URL を確定させてから信頼ポリシーを更新する、という順番になります
  - このハンズオンでは独自の固定文字列にしてあるので、その往復が不要です

なぜ `sub` だけでは不十分なのか——`aud` を確認しないと、
**同じサービスアカウントが別の用途で取得したトークンを、AWS への入館に流用できてしまいます。**
`aud` は「このトークンは AWS 向けです」という但し書きの役割を果たします。

### 条件キーの違い（混乱しやすい点）

| 条件キー | 実際に参照されるクレーム |
| --- | --- |
| `accounts.google.com:oaud` | 常に `aud` ← **これを使う** |
| `accounts.google.com:aud` | `azp` があればそれ、なければ `aud` |
| `accounts.google.com:sub` | `sub` |

`azp`（authorized party）は OAuth クライアント ID を表すクレームで、
発行方法によって入ったり入らなかったりします。
**素直に `aud` を見たいなら `oaud`** を使うのが確実です。

### 実測で確かめた azp の罠

このハンズオンで実際に発行された ID トークンの payload は次のとおりでした。

```json
{
  "aud": "https://cloud-run-s3-handson.example.com",
  "azp": "<SA_UNIQUE_ID>",
  "email": "aws-access@<PROJECT_ID>.iam.gserviceaccount.com",
  "sub": "<SA_UNIQUE_ID>",
  "iss": "https://accounts.google.com"
}
```

**`azp` が入っており、その値は `sub` と同じ uniqueId です。**

つまり `accounts.google.com:aud` 条件を使うと、audience 文字列ではなく
**uniqueId と比較される**ことになり、`https://...` を書いても永遠に一致しません。

実際に STS のレスポンスを見ると、この挙動がはっきり現れます。

```json
{
  "SubjectFromWebIdentityToken": "<SA_UNIQUE_ID>",
  "Audience": "<SA_UNIQUE_ID>"      ← aud ではなく azp が返っている
}
```

`oaud` を使う理由は、この一点に尽きます。

---

## 許可ポリシーとの対比

信頼ポリシーを通ったら、次は許可ポリシーの出番です。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-bucket",
        "arn:aws:s3:::my-bucket/*"
      ]
    }
  ]
}
```

| | 信頼ポリシー | 許可ポリシー |
| --- | --- | --- |
| 問い | 誰がこのロールになれるか | なった後、何ができるか |
| 失敗したときのエラー発生源 | STS（`AssumeRoleWithWebIdentity` が `AccessDenied`） | S3（`GetObject` が `AccessDenied`） |

### Resource を 2 行書く理由

```json
"arn:aws:s3:::my-bucket"      ← バケット自身。ListBucket 用
"arn:aws:s3:::my-bucket/*"    ← 中のオブジェクト。GetObject 用
```

S3 の API は対象リソースの粒度が違います。

- `s3:ListBucket` は**バケット**に対する操作 → `/*` なしの ARN が必要
- `s3:GetObject` は**オブジェクト**に対する操作 → `/*` 付きの ARN が必要

片方だけ書くと「一覧はできるが読めない」「読めるが一覧できない」という
中途半端な状態になります。よくあるハマりどころです。

> S3 の ARN にリージョンとアカウント ID が入らない（`:::` と空欄が続く）のは、
> バケット名がグローバルに一意だからです。

---

## 書き込みも許可したい場合

```json
"Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
```

`s3:PutObject` を足すだけです。**信頼ポリシーは変更しません。**
「誰が入れるか」は変わらず、「何ができるか」だけが変わるからです。

この分離が理解できていれば、権限設計で迷うことはありません。
