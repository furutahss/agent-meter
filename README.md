# Agent Meter

Codex、Antigravity、Claude Code、Grok の残り使用量を、macOS のメニューバーでまとめて確認するネイティブアプリです。Xcode でそのままビルドでき、今後ほかのエージェントCLIを追加しやすい provider 構成になっています。

## 現在の対応

| エージェント | 取得元 | 表示内容 |
|---|---|---|
| Codex | `codex app-server --stdio` | 主／第2制限、複数limit、残量、リセット時刻、プラン、クレジット |
| Antigravity | `agy` の対話的 `/usage` | Gemini系・Claude/GPT系それぞれの週次／5時間残量と更新時刻 |
| Claude Code | `claude` の対話的 `/usage` | セッション（5時間）・週次残量、リセット時刻、プラン、クレジット |
| Grok | `grok agent --no-leader stdio` の請求情報 | 現在期間の使用率、リセット時刻、プラン、前払いクレジット、従量課金 |

メニューバーでは、左端にAgent Meterのアプリアイコン、その右側に「小さいエージェントアイコン＋緑色の残量バー」を縦2段で表示します。3番目以降のエージェントは同じ2段構成のまま右側へ列を追加するため、頭文字の重複や横幅の増えすぎを避けられます。クリックすると、5時間枠・週次枠・残量・リセット日時など、取得できた全制限をエージェント別カードで確認できます。

## 主な機能

- 残量／使用量の切り替え
- 1・5・15・30分または手動更新
- エージェントごとの独立した取得、エラー、キャッシュ表示
- 残量通知とログイン時起動
- ライト／ダーク表示、VoiceOver向けラベル
- 認証情報を直接読み取らず、インストール済みCLIのログイン状態を利用

## 起動

前提は macOS 14 以降、Xcode、ログイン済みの `codex`、`agy`、`claude`、`grok` です。

1. `AgentMeter.xcodeproj` を Xcode で開く。
2. `AgentMeter` scheme、`Debug` configurationを選ぶ。
3. Run（⌘R）する。

詳しくは [ローカル利用手順](docs/LOCAL_USE.md) を参照してください。

## 構成

`UsageProvider` がCLI固有処理をUIから分離しています。新しいエージェントは同protocolを実装し、`UsageViewModel` のprovider登録へ加えることで対応できます。

```text
NSStatusItem / SwiftUI
        |
UsageViewModel
        |
UsageProvider
   |                 |                      |                 |
AppServerProvider   AntigravityCLIProvider  ClaudeCLIProvider GrokCLIProvider
   |                 |                      |                 |
codex app-server    agy /usage (PTY)        claude /usage     grok agent billing
```

AntigravityやClaude CodeのCLI画面は安定APIではないため、CLI更新で表示形式が変わった場合は該当エージェントカードだけを「非対応」とし、他のエージェント表示とキャッシュは継続します。

## 検証

```bash
swift test
xcodebuild build \
  -project AgentMeter.xcodeproj \
  -scheme AgentMeter \
  -configuration Debug \
  -destination 'platform=macOS'
```

このアプリは個人利用・直接配布向けです。App Storeへの公開を前提としていません。`Beta`構成は署名なし／adhoc署名のローカル配置でも埋め込みFrameworkを読み込めるよう、Hardened Runtimeを無効にしています。他のMacへ配布する場合はDeveloper ID署名とNotarizationを設定した配布専用構成を利用してください。
