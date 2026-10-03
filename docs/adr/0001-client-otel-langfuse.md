Superseded by 0003-standard-otlp-observability-boundary

# クライアントからLangfuseへOpenTelemetryトレースを常時送信する

Date: 2026-09-20

設計03では外部LLMのトレースをproxy側に限定しclient SDKを却下したが、MCPツール、カード描画、評価を含む端末内の一連の処理はproxyから観測できない。個人利用の運用判断として、公式OpenTelemetry Swift 2.5系をTracing only・alwaysOnで組み込み、設定可能なLangfuse OTLP/HTTP protobuf endpointへprompt/response/tool I/Oを含む全spanを直接送信し、pk/skはKeychainへ保存するため、設計03 §3の該当決定を本ADRで置き換える。

Rejected: proxy側だけの計装ではclient固有のMCP、カード、評価を同じtraceとして取得できないため。
Rejected: 独自OTLP JSON exporterは公式SDKのprotobuf exporterとbatch処理を重複実装するため。
