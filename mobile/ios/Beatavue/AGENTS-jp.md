## 開発とXcode MCPのガイドライン

- **Xcodeツール**: ビルド、検証、プロジェクト設定には、必ずXcode MCPツール（`BuildProject`、`RunAllTests`、`AddInfoPlist`、`XcodeRM`など）を使う。
  - 明示的な指示がない限り、`xcodebuild`などのコマンドラインツールでビルドや検証を行わない。

## 検証手順

作業を完了する前に、次を行う。

1. `make lint`を実行し、すべてのSwiftコードを整形する。
2. Xcode MCP（`BuildProject`）でプロジェクトをビルドする。
3. 指示がない限り、テストスイートを実行しない。

[English](AGENTS.md)
