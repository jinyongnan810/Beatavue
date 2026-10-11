# Beatavue

[日本語](README-jp.md) · [Tech](tech.md) · [Setup](setup.md) · [Web](https://beatavue.web.app)

Beatavue helps view the heart rate and heart-rate variability (HRV) on iPhone and the web.

- **iPhone:** View history from Apple Health.
- **Apple Watch:** See live heart rate from a Watch workout on iPhone.
- **Web:** Share history through a public dashboard with day, week, and month views. 

## Main purpose

Check HealthKit automatically triggers app when new heart rate or heart-rate variability (HRV) data is available. And the app can fetch and upload the data to server without launching.

## In this repository

- [Mobile](mobile/ios/Beatavue/README.md) — iPhone and Apple Watch apps built with SwiftUI.
- [API](api/README.md) — Python service that stores and serves history using Firestore.
- [Web](web/README.md) — React and TypeScript dashboard.
- [Infra](infra/README.md) — Terraform configuration for cloud hosting.
- [Scripts](scripts/) — Deployment tools.
