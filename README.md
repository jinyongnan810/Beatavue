# Beatavue

An iPhone and Apple Watch heart-rate/HRV journal with optional public cloud publishing.

- [Project specification](spec.md)
- [iOS and Watch setup](mobile/ios/Beatavue/README.md)
- [API contract and local development](api/README.md)
- [GCP bootstrap and deployment](infra/README.md)
- [Dashboard development](web/README.md)

Scope 2 targets the existing GCP project **beatavue**, number **256425564793**.
Publishing is disabled by default. No health data or upload token is included in this repository.
The serverless API and dashboard must be deployed before enabling publishing on a device.
