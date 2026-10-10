# infra/

[English](README.md) · [技術](../tech-jp.md) · [セットアップ](../setup-jp.md)

`beatavue` · `256425564793` · 東京

```mermaid
flowchart TB
    subgraph Build[ビルド]
        Source["GCSソースバケット<br/>beatavue-function-source"]
        Builder["サービスアカウント<br/>beatavue-builder"]
        BuildJob["Cloud Build<br/>GCP管理のジョブ"]
        Images["Artifact Registry<br/>beatavue-functions"]
        Source -->|ソースZIP| BuildJob
        BuildJob -->|イメージ作成| Images
        BuildJob -.->|実行ID| Builder
        Builder -.->|ソース読取| Source
        Builder -.->|イメージ書込| Images
        Builder -.->|ビルドログ書込| Logs[Cloud Logging]
    end

    subgraph Runtime[実行環境]
        API["公開Cloud Run関数<br/>beatavue-api"]
        Queue["Cloud Tasksキュー<br/>beatavue-cleanup"]
        Worker["非公開Cloud Run関数<br/>beatavue-cleanup"]
        DB[("Firestore<br/>デフォルトDB")]
        Secret["Secret Managerシークレット<br/>beatavue-upload-token"]
        Index[サンプル索引]
        Rules[Firestoreルールセット]
        Release[ルール公開設定]
        Alert[5xx監視ポリシー]
        API -->|読取・書込| DB
        API -->|削除を登録| Queue
        Queue -->|OIDC呼出| Worker
        Worker -->|消去| DB
        Secret -->|トークン注入| API
        Index --- DB
        Rules --> Release
        Release -->|直接アクセス拒否| DB
        API -.->|5xxメトリクス| Alert
        Worker -.->|5xxメトリクス| Alert
    end

    subgraph IAM[サービスアカウントとIAM]
        ApiIdentity[beatavue-api]
        WorkerIdentity[beatavue-cleanup]
        TaskIdentity[beatavue-tasks]
        API -.->|実行ID| ApiIdentity
        Worker -.->|実行ID| WorkerIdentity
        ApiIdentity -.->|DBアクセス| DB
        WorkerIdentity -.->|DBアクセス| DB
        ApiIdentity -.->|シークレット読取| Secret
        ApiIdentity -.->|キュー登録権限| Queue
        ApiIdentity -.->|実行IDを借用| TaskIdentity
        Queue -.->|OIDC認証ID| TaskIdentity
        TaskIdentity -.->|呼出権限| Worker
    end

    Images -->|イメージ配備| API
    Images -->|イメージ配備| Worker
    Public[公開呼出元] -->|公開呼出IAM| API
    Services[17個の有効なGCP API] -.-> Build
    Services -.-> Runtime
    Budget["請求予算<br/>任意"] -.->|プロジェクト支出| Runtime

    subgraph Bootstrap[Terraform外で準備]
        State["非公開・世代管理付きGCS状態<br/>beatavue-terraform-state"]
        Terraform[Terraform]
        Hosting["Firebase Hosting<br/>beatavue"]
        Token[所有者トークンのバージョン]
        State <-->|リモート状態| Terraform
        Hosting -->|API書き換え| API
        Token -->|別途登録| Secret
    end
```

名前付きの資源とIAM権限をTerraformで作成。Cloud BuildジョブとCloud LoggingはGCP管理の
サービス。状態、Hosting、トークン値は別途準備する。予算は任意。
