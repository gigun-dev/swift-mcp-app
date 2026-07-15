// S2 の transport 疎通確認専用の隠し画面(設計 §6-S2 / タスク指示)。
//
// 目的: caldav にも状態機械(S3)にも一切依存せず、WebViewTransport 単体で
// 設計 §1 の3仮説(parent===window / isTrusted 方向判別 / stopImmediatePropagation の
// 登録順)を simctl screenshot で潰せるようにする。起動環境変数 MCPHOST_SPIKE=transport の
// とき MCPHostApp のルートをこの画面にする(P1 の MCPHOST_AUTOCONNECT と同じ流儀)。
//
// 画面には次が可視になる(タスクの判定3点):
//  1. ホスト側パネルに「View→Host 受信: method=echo」(parent===window で送信が Swift に届いた)
//  2. ホスト側「Host→View 配送済み」→ ミニ HTML 側ログに「received isTrusted=false」
//     (合成イベントが View に届く = Host→View 経路成立)
//  3. ミニ HTML 側ログに「self-loopback: none」(stopImmediatePropagation が効き、View 自身が
//     送った echo が自分のリスナーに返ってこない)
import SwiftUI
import OSLog
import WebKit
import Services
import Kernel

/// ミニ HTML(設計 §6-S2 の「10行ミニ HTML」)。
/// - documentStart 後に window.parent.postMessage で echo リクエストを送る(View→Host 検証)。
/// - 自分でも message リスナー(bubble フェーズ)を張り、届いたイベントの isTrusted を
///   画面ログに書く(Host→View 検証 & ループバック無し確認)。
///   ※ このリスナーは capture ではないので、インターセプタ(capture + stopImmediatePropagation)が
///     効けば View 自身の echo は here に届かない = self-loopback: none になるはず。
private let miniHTML = """
<!DOCTYPE html>
<html>
<head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family:-apple-system,system-ui;font-size:15px;padding:14px;margin:0">
  <h3 style="margin:0 0 8px">mini view (ext-apps App 相当)</h3>
  <div id="log" style="white-space:pre-wrap;line-height:1.5"></div>
  <script>
    var logEl = document.getElementById("log");
    function add(s) { var d = document.createElement("div"); d.textContent = s; logEl.appendChild(d); }
    var gotLoopback = false;
    // 自分の受信リスナー(bubble)。Host→View 配送 & ループバック検査の両方を担う。
    window.addEventListener("message", function (e) {
      if (!e.data || e.data.jsonrpc !== "2.0") return;
      if (e.data.method === "echo") {
        // 自分が送った echo が自分に返ってきた = ループバック(あってはならない)。
        gotLoopback = true;
        add("self-loopback: DETECTED (bug!)");
        return;
      }
      add("received isTrusted=" + e.isTrusted + "  " + JSON.stringify(e.data));
    });
    // View→Host 送信。parent===window なので実質 window.postMessage(自分宛て・本物イベント)。
    window.parent.postMessage({ jsonrpc: "2.0", id: 1, method: "echo", params: { hello: "from-view" } }, "*");
    add("sent echo (View->Host)");
    // 少し待ってループバックが起きなかったことを明示表示(設計 §6 ゲート3項目め)。
    setTimeout(function () { if (!gotLoopback) add("self-loopback: none"); }, 400);
  </script>
</body>
</html>
"""

@MainActor
final class TransportSpikeViewModel: ObservableObject {
    // ホスト側(Swift)で観測した節目を並べる。SwiftUI パネルに出す。
    @Published private(set) var hostLog: [String] = []

    let transport = WebViewTransport()
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appsbridge")
    private var consumeTask: Task<Void, Never>?

    func start() {
        guard consumeTask == nil else { return }
        append("spike 開始: View→Host の echo を待機")
        // transport.incoming を消費して、echo リクエストを受けたら Host→View に応答を配送する。
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await item in self.transport.incoming {
                await self.handle(item.message)
            }
        }
    }

    private func handle(_ message: JSONRPCMessage) async {
        // 期待するのは View が送った echo リクエストのみ。
        guard case .request(let request) = message, request.method == "echo" else {
            append("想定外メッセージ: \(message)")
            return
        }
        // 判定1: parent===window で送信が Swift に届いたことの可視化。
        append("View→Host 受信: method=\(request.method)")
        logger.notice("spike 判定1 OK: View→Host 受信 method=echo")

        // Host→View に応答を配送(判定2)。id は echo と同じ 1、result は echoed:true。
        let response = JSONRPCResponse(id: request.id, result: ["echoed": true])
        await transport.deliver(response: response)
        append("Host→View 配送済み")
        logger.notice("spike 判定2: Host→View 配送済み(ミニ HTML 側 isTrusted=false を確認)")
    }

    private func append(_ line: String) {
        hostLog.append(line)
    }
}

/// WKWebView を SwiftUI に載せる薄いラッパ。transport の configuration で生成し、
/// 生成後に attach、ミニ HTML をロードするだけ。
private struct SpikeWebView: UIViewRepresentable {
    let transport: WebViewTransport

    func makeUIView(context: Context) -> WKWebView {
        // transport が組んだ configuration(documentStart インターセプタ + 弱参照ハンドラ)で生成。
        let webView = WKWebView(frame: .zero, configuration: transport.makeConfiguration())
        transport.attach(to: webView)
        // baseURL: nil = opaque origin 相当(設計 §4)。postMessage は targetOrigin "*" なので通る。
        webView.loadHTMLString(miniHTML, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct TransportSpikeView: View {
    @StateObject private var viewModel = TransportSpikeViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 上段: ホスト側(Swift)の観測ログ。判定1・「Host→View 配送済み」がここに出る。
            VStack(alignment: .leading, spacing: 4) {
                Text("AppsBridge transport spike — Host 側")
                    .font(.headline)
                ForEach(Array(viewModel.hostLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(white: 0.95))

            Divider()

            // 下段: ミニ HTML(View 側)。received isTrusted=false / self-loopback: none がここに出る。
            SpikeWebView(transport: viewModel.transport)
        }
        .onAppear { viewModel.start() }
    }
}
