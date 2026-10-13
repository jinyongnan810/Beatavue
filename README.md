# Beatavue

[English](README-en.md) · [技術](tech-jp.md) · [セットアップ](setup-jp.md) · [Web](https://beatavue.web.app)

Beatavueは、iPhoneとWebで心拍数と心拍変動（HRV）を確認できるアプリです。

- **iPhone:** Appleヘルスケアに記録された履歴を表示します。
- **Apple Watch:** ワークアウト中のリアルタイム心拍数をiPhoneで確認し、公開設定を有効にするとWebへ送信できます。
- **Web:** 日・週・月単位で表示できる公開ダッシュボードを通じて履歴とワークアウト中のリアルタイム心拍数を共有します。

## 確認できたこと

- 新しい心拍数や心拍変動（HRV）のデータが利用可能になったときに、HealthKitがアプリを自動的に起動し、アプリを手動で開かなくても(kill状態でも)データを取得してサーバーにアップロードできる。
  - ただ、すぐというのではなく、一日数回ぐらいで不定期でアップロードされる
  - 毎日放置しても自動更新自体はサボらず、必ずアップデートしてくれるのではある
- Apple Watchでワークアウト中のリアルタイム心拍数をiPhoneで確認できる。
  - Apple Watchアプリ単体(iPhone&Watch wifi off, iPhone 5g on, ios app off)でもリアルタイム心拍数をアップロードできる。
- Apple Watchの場合
  - ワークアウト中は頻繁に心拍数が更新される。
  - ワークアウトしていない場合、およそ5分に一回心拍数が更新される。(Series 12の場合はもっと頻繁かもしれない)
  - HRVは2時間に一回更新される。

## リポジトリの構成

- [モバイル](mobile/ios/Beatavue/README.md) — SwiftUIで作成したiPhone・Apple Watchアプリ。
- [API](api/README.md) — Firestoreを使って履歴を保存・配信するPythonサービス。
- [Web](web/README.md) — ReactとTypeScriptで作成したダッシュボード。
- [基盤](infra/README.md) — クラウドホスティングのTerraform設定。
- [スクリプト](scripts/) — デプロイ用ツール。
