// P4 スパイク(2026-07-16): WKWebView を SwiftUI 階層間(inline ↔ sheet)で reparent したとき
// JS 状態・Web プロセスが保たれるかを実測する。設計 04(displayMode ネゴシエーション)の §6-1
// 「最大のリスク」を実装前に潰すための最小ハーネス。MCP 接続は不要(自己完結 HTML)。
//
// 【何を確かめるか】
//  1. 同一 WKWebView インスタンスを inline と sheet の2箇所の UIViewRepresentable が指すとき、
//     sheet 提示で webView が sheet 側 superview へ移り、inline 側が空になる/ならないか。
//  2. sheet の中でカードの JS 状態(カウンタ・入力欄テキスト)が保たれるか(= 再ロードされない)。
//  3. sheet dismiss 後に inline へ webView が戻るか(戻らなければ「戻し」の明示処理が要る)。
//
// 【判定の仕掛け】HTML に setInterval で 100ms ごとに +1 する「tick カウンタ」を仕込む。
//   reparent で再ロードされれば tick は 0 に戻り interval も貼り直しになる。保たれれば
//   連続した値のまま。加えて手動 +1 ボタンと入力欄(未コミットの編集途中状態の代理)を置く。
//
// 【本番との対応】InlineCardHost が webView を強保持し、inline は AppCardView で載せるだけ、
//   という本番の構造(InlineCardView.swift:39-70)をそのまま縮小再現する。ここで判明した
//   「正しい reparent の形」を設計 04 に「> 更新」で書き戻す。
import SwiftUI
import WebKit
import OSLog

/// reparent 検証用に、単一の WKWebView を強保持するだけの最小ホスト(本番 InlineCardHost の縮小版)。
@MainActor
@Observable
final class ReparentSpikeHost {
    private(set) var webView: WKWebView?
    /// 直近に評価した「JS 側の状態スナップショット」文字列(tick / manual / input を native に吸い上げた値)。
    var lastProbe: String = "(未取得)"

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "reparent-spike")

    func buildIfNeeded() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(Self.html, baseURL: nil)
        self.webView = webView
        logger.notice("spike webView を生成・ロード")
    }

    /// JS 側の状態(tick/manual/入力欄)を吸い上げて lastProbe に反映する。
    /// reparent 前後で呼び、値が連続していれば「状態が保たれた」証拠になる。
    /// superview のクラス名も併記し、webView が今どの階層にぶら下がっているかを可視化する。
    func probe(_ context: String) {
        guard let webView else { return }
        let superName = webView.superview.map { String(describing: type(of: $0)) } ?? "nil(どこにも載っていない)"
        let script = "JSON.stringify({tick: window.__tick, manual: window.__manual, "
            + "input: document.getElementById('field').value})"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                if let probeResult = result as? String {
                    self?.lastProbe = "[\(context)] \(probeResult)"
                    let probeLog = "PROBE \(context): \(probeResult) superview=\(superName)"
                    self?.logger
                        .notice("\(probeLog, privacy: .public)")
                } else if let error {
                    self?.lastProbe = "[\(context)] error: \(error.localizedDescription)"
                    self?.logger
                        .error("PROBE \(context, privacy: .public) 失敗: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
    }

    /// JS 側の状態を書き換える(手動カウンタ=5・入力欄="hello")。自動シナリオの「編集途中状態」を作る。
    func seedState() {
        guard let webView else { return }
        let script = "window.__manual=5;document.getElementById('manual').textContent=5;"
            + "document.getElementById('field').value='hello';"
        webView.evaluateJavaScript(script)
    }

    // tick: 100ms ごとに自動 +1(interval が生きている=プロセス継続の証拠)。
    // __manual: ボタンで +1(明示的なユーザ操作状態)。field: 入力途中テキストの代理。
    static let html = """
    <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
    <style>
      body{font-family:-apple-system;margin:0;padding:16px;background:#eef}
      .big{font-size:44px;font-weight:700;font-variant-numeric:tabular-nums}
      button{font-size:20px;padding:10px 18px;margin:8px 0}
      input{font-size:18px;padding:8px;width:90%}
      .box{background:#fff;border-radius:12px;padding:16px;margin:8px 0}
    </style></head><body>
      <div class=box>
        <div>自動 tick(100ms 毎・リロードで0に戻る)</div>
        <div class=big id=tick>0</div>
      </div>
      <div class=box>
        <div>手動カウンタ</div>
        <div class=big id=manual>0</div>
        <button onclick="window.__manual++;document.getElementById('manual').textContent=window.__manual">+1</button>
      </div>
      <div class=box>
        <div>入力途中テキスト(未コミット状態の代理)</div>
        <input id=field placeholder="ここに何か入力">
      </div>
      <script>
        window.__tick = 0; window.__manual = 0;
        setInterval(function(){ window.__tick++; document.getElementById('tick').textContent = window.__tick; }, 100);
      </script>
    </body></html>
    """
}

/// 準備済み webView を **container 経由で** 載せる Representable(再アダプト方式)。
///
/// 素朴に makeUIView で webView を直接返すと、sheet 側が webView を奪ったあと dismiss しても
/// SwiftUI が inline 側の makeUIView を再呼び出ししないため webView が orphan(superview=nil)に
/// なる(スパイク第1回で実証)。対処: 各所は「空の container UIView」を返し、updateUIView で
/// 「自分の container に webView が載っていなければ載せ直す」= 再アダプトする。SwiftUI は
/// sheet dismiss 時に inline 側 updateUIView を再評価するので、そこで inline が webView を取り戻す。
private struct SpikeCardView: UIViewRepresentable {
    let webView: WKWebView
    // 再アダプトを強制するためのトークン。値が変わると SwiftUI が updateUIView を呼び直す。
    // dismiss 時にこれを bump することで、inline がここで webView を取り戻す。既定 0(sheet 側は不変)。
    var rehomeToken: Int = 0
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        adopt(into: container)
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        // 他所(sheet)に奪われて container が空、または別の親に居るなら、この container へ載せ直す。
        if webView.superview !== container { adopt(into: container) }
    }
    private func adopt(into container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}

/// reparent スパイクのルート画面。inline にカードを出し、「全画面で開く」で sheet に
/// 同一 webView を載せ替える。上部の probe 表示で JS 状態の連続性を目視する。
struct ReparentSpikeView: View {
    @State private var host = ReparentSpikeHost()
    @State private var showingSheet = false
    // dismiss のたびに +1 して inline の SpikeCardView に webView 再アダプトを促す。
    @State private var rehomeToken = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("reparent スパイク").font(.headline)
            // probe の結果(tick/manual/input)。sheet 開閉の前後でここが連続していれば状態保持。
            Text(host.lastProbe).font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Color(white: 0.92)).clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("probe(inline)") { host.probe("inline") }
                Button("全画面で開く") {
                    host.probe("sheet直前")
                    showingSheet = true
                }.buttonStyle(.borderedProminent)
            }

            // inline のカード枠。sheet に webView が移ったあと、ここが空になるか観察する。
            ZStack {
                RoundedRectangle(cornerRadius: 12).stroke(Color.gray).background(Color(white: 0.97))
                if let webView = host.webView {
                    SpikeCardView(webView: webView, rehomeToken: rehomeToken)
                }
                Text("inline 枠(webView が居れば上に描画)").foregroundStyle(.secondary)
            }
            .frame(height: 360)
            Text("↑ sheet を閉じた後、ここにカードが戻るか？").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .task {
            host.buildIfNeeded()
            // 自動シナリオ(MCPHOST_SPIKE=reparent-auto のとき): タップ駆動なしで
            // seed → probe(前) → sheet 提示 → probe(sheet内) → dismiss → probe(後) を回し、
            // 各段階を os_log に吐く。エージェントがログだけで判定できるようにする。
            if ProcessInfo.processInfo.environment["MCPHOST_SPIKE_AUTO"] == "1" {
                try? await Task.sleep(for: .seconds(1.5))   // tick を進めてから
                host.seedState()
                try? await Task.sleep(for: .milliseconds(300))
                host.probe("A_sheet提示前")
                try? await Task.sleep(for: .milliseconds(300))
                showingSheet = true                          // reparent(inline→sheet)
                try? await Task.sleep(for: .seconds(1.5))
                host.probe("B_sheet表示中")
                try? await Task.sleep(for: .seconds(1))
                showingSheet = false                         // reparent(sheet→inline)
                rehomeToken += 1                              // inline に再アダプトを促す
                try? await Task.sleep(for: .seconds(1.5))
                host.probe("D_dismiss完了後")
            }
        }
        .sheet(
            isPresented: $showingSheet,
            onDismiss: {
                rehomeToken += 1   // 手動で閉じたときも inline に再アダプトを促す
                // dismiss 直後に inline 側の状態を確認(webView が inline に戻っているか含む)。
                host.probe("dismiss後")
            },
            content: { SheetContent(host: host) }
        )
    }
}

/// sheet 側(fullscreen 相当)。同一 webView を internal スクロール有効で載せる。
private struct SheetContent: View {
    let host: ReparentSpikeHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("sheet(fullscreen 相当)").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
            }.padding(.horizontal)
            Button("probe(sheet 内)") { host.probe("sheet内") }
            if let webView = host.webView {
                // sheet では内部スクロール可に切替(本番の fullscreen と同じ想定)。
                SpikeCardView(webView: webView)
                    .onAppear { webView.scrollView.isScrollEnabled = true }
                    .onDisappear { webView.scrollView.isScrollEnabled = false }
            } else {
                Text("webView なし")
            }
        }
        .padding(.vertical)
        .task {
            // 提示直後に probe(reparent 直後の JS 状態が保たれているか)。
            host.probe("sheet表示直後")
        }
    }
}
