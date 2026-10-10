# infra/

[日本語](README-jp.md) · [Tech](../tech.md) · [Setup](../setup.md)

`beatavue` · `256425564793` · Tokyo

```mermaid
flowchart TB
    subgraph Build[Build]
        Source["GCS source bucket<br/>beatavue-function-source"]
        Builder["Service account<br/>beatavue-builder"]
        BuildJob["Cloud Build<br/>GCP-managed jobs"]
        Images["Artifact Registry<br/>beatavue-functions"]
        Source -->|Source ZIP| BuildJob
        BuildJob -->|Build image| Images
        BuildJob -.->|Runs as| Builder
        Builder -.->|Read source| Source
        Builder -.->|Write images| Images
        Builder -.->|Write build logs| Logs[Cloud Logging]
    end

    subgraph Runtime[Runtime]
        API["Public Cloud Run function<br/>beatavue-api"]
        Queue["Cloud Tasks queue<br/>beatavue-cleanup"]
        Worker["Private Cloud Run function<br/>beatavue-cleanup"]
        DB[("Firestore<br/>default database")]
        Secret["Secret Manager container<br/>beatavue-upload-token"]
        Index[Samples index]
        Rules[Firestore ruleset]
        Release[Rules release]
        Alert[5xx monitoring policy]
        API -->|Read and write| DB
        API -->|Enqueue deletion| Queue
        Queue -->|OIDC invocation| Worker
        Worker -->|Purge| DB
        Secret -->|Inject token| API
        Index --- DB
        Rules --> Release
        Release -->|Deny direct clients| DB
        API -.->|5xx metrics| Alert
        Worker -.->|5xx metrics| Alert
    end

    subgraph IAM[Service accounts and IAM]
        ApiIdentity[beatavue-api]
        WorkerIdentity[beatavue-cleanup]
        TaskIdentity[beatavue-tasks]
        API -.->|Runs as| ApiIdentity
        Worker -.->|Runs as| WorkerIdentity
        ApiIdentity -.->|Database access| DB
        WorkerIdentity -.->|Database access| DB
        ApiIdentity -.->|Secret access| Secret
        ApiIdentity -.->|Enqueue permission| Queue
        ApiIdentity -.->|Act as| TaskIdentity
        Queue -.->|OIDC identity| TaskIdentity
        TaskIdentity -.->|Invoker permission| Worker
    end

    Images -->|Deploy image| API
    Images -->|Deploy image| Worker
    Public[Public callers] -->|Public invoker IAM| API
    Services[17 enabled GCP APIs] -.-> Build
    Services -.-> Runtime
    Budget["Billing budget<br/>Optional"] -.->|Project spending| Runtime

    subgraph Bootstrap[Outside Terraform]
        State["Private versioned GCS state<br/>beatavue-terraform-state"]
        Terraform[Terraform]
        Hosting["Firebase Hosting<br/>beatavue"]
        Token[Owner token version]
        State <-->|Remote state| Terraform
        Hosting -->|API rewrite| API
        Token -->|Provision separately| Secret
    end
```

Terraform creates the named resources and IAM bindings. Cloud Build jobs and Cloud Logging are
GCP-managed services. State, Hosting, and token values are bootstrapped separately. Budget is optional.
