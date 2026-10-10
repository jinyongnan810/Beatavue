# mobile/ios/Beatavue/

[日本語](README-jp.md) · [Tech](../../../tech.md) · [Setup](../../../setup.md)

History on iPhone. Live heart rate on Watch.

```mermaid
flowchart LR
    Health[Apple Health] --> Phone[iPhone · History]
    Watch[Watch · Live] --> Phone
    Phone -.->|Optional publishing| Web[Web]
```

[iPhone](Beatavue/) · [Watch](<Beatavue Watch Watch App/>) · [Xcode](Beatavue.xcodeproj/)
