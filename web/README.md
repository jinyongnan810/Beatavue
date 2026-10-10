# web/

[日本語](README-jp.md) · [Tech](../tech.md) · [Setup](../setup.md) · [Open](https://beatavue.web.app)

Public heart-rate and HRV history.

```mermaid
flowchart LR
    API[History] --> UI[src/ · Dashboard]
    UI --> Visitor[Anyone]
```

[Source](src/)

The dashboard supports English and Japanese, defaults to the browser language, and remembers the language selected in the header.
