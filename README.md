# Beatavue

[日本語](README-jp.md) · [Tech](tech.md) · [Setup](setup.md) · [Web](https://beatavue.web.app)

Heart history. iPhone, Watch, web.

```mermaid
flowchart LR
    M[mobile · Capture] --> A[api · Share]
    A --> W[web · View]
    I[infra · Host] -.-> A
    I -.-> W
    S[scripts · Deploy] -.-> I
```

[Mobile](mobile/ios/Beatavue/README.md) · [API](api/README.md) · [Web](web/README.md) · [Infra](infra/README.md) · [Scripts](scripts/)
