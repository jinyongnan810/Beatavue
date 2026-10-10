# api/

[日本語](README-jp.md) · [Tech](../tech.md) · [Setup](../setup.md)

Health data. Upload, read, delete.

```mermaid
flowchart LR
    Phone[iPhone] -->|Upload| API[api/]
    API -->|History| Web[Web]
    API -->|Delete| Cleanup[Cleanup]
```

[Checks](tests/)
