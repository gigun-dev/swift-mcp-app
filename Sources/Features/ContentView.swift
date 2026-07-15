// P0 時点では「アプリが起動して画面が出る」ことを目視確認するための仮実装。
// P1(接続 MVP)で tools/list の結果を表示する画面に差し替わる想定なので、
// レイアウトを凝らず最小限に留めている。
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("MCPHost")
            .font(.largeTitle)
            .padding()
    }
}

#Preview {
    ContentView()
}
