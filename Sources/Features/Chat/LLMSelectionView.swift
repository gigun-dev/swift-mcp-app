import SwiftUI
import Kernel

/// OpenAI互換プロバイダへ送るreasoning_effortと、画面で使う短い日本語名の対応。
enum LLMReasoningEffort {
    struct Option: Identifiable {
        let id: String
        let label: String
        let detail: String
    }

    private static let allOptions = [
        Option(id: "", label: "自動", detail: "接続先の既定値を使います"),
        Option(id: "low", label: "低", detail: "軽い推論で素早く応答します"),
        Option(id: "medium", label: "中", detail: "速度と推論のバランスを取ります"),
        Option(id: "high", label: "高", detail: "複雑な課題を丁寧に検討します"),
        Option(id: "xhigh", label: "超高", detail: "より深く推論します"),
        Option(id: "max", label: "最大", detail: "利用可能な最大エフォートを使います"),
        Option(id: "ultra", label: "ウルトラ", detail: "対応モデルで最上位の推論を使います")
    ]

    static func label(for id: String) -> String {
        allOptions.first(where: { $0.id == id })?.label ?? id
    }

    /// `/v1/models`にはreasoning effort能力の標準フィールドが無いため、確認できたモデルだけを
    /// 明示対応する。未知モデルへ推測値を送らず、自動(フィールド省略)だけを提示する。
    static func options(for model: String) -> [Option] {
        let ids: [String]
        switch model {
        case "gpt-5.5": ids = ["", "low", "medium", "high", "xhigh"]
        case "gpt-5.6-luna": ids = ["", "low", "medium", "high", "xhigh", "max"]
        case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra":
            ids = ["", "low", "medium", "high", "xhigh", "max", "ultra"]
        default: ids = [""]
        }
        return ids.compactMap { id in allOptions.first(where: { $0.id == id }) }
    }

    @MainActor
    static func normalize(_ store: LLMSettingsStore) {
        let validIDs = Set(options(for: store.model).map(\.id))
        if !validIDs.contains(store.reasoningEffort) { store.reasoningEffort = "" }
    }
}

/// 設定画面から開くモデル一覧。価格はこの一覧にだけ表示し、選択後の設定行には重ねて出さない。
struct LLMModelListView: View {
    @Bindable var store: LLMSettingsStore
    let prices: [String: ModelPrice]
    var onSelectionChanged: () -> Void = {}

    var body: some View {
        List {
            Section {
                ForEach(models, id: \.self) { model in
                    Button {
                        store.model = model
                        LLMReasoningEffort.normalize(store)
                        onSelectionChanged()
                    } label: {
                        HStack(spacing: 12) {
                            Text(model)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if let price = LLMPriceText.compact(model: model, prices: prices) {
                                Text(price)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if store.model == model {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            Section("一覧にないモデル") {
                TextField("モデルIDを直接入力", text: $store.model)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        LLMReasoningEffort.normalize(store)
                        onSelectionChanged()
                    }
            }
        }
        .navigationTitle("利用可能なモデル")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var models: [String] {
        store.availableModels.contains(store.model)
            ? store.availableModels
            : [store.model] + store.availableModels
    }
}

/// モデルとは独立してreasoning_effortを選ぶ画面。未対応値も捨てず、現在値として残す。
struct LLMReasoningEffortView: View {
    @Bindable var store: LLMSettingsStore
    var onSelectionChanged: () -> Void = {}

    var body: some View {
        List(LLMReasoningEffort.options(for: store.model)) { option in
            Button {
                store.reasoningEffort = option.id
                onSelectionChanged()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(option.label).foregroundStyle(.primary)
                            if option.id.isEmpty {
                                Text("デフォルト")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                            }
                        }
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.reasoningEffort == option.id {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                }
            }
        }
        .navigationTitle("エフォート")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// composerのピルから開く、モデルとエフォートを1つにまとめたボトムシート。
struct LLMSelectionSheet: View {
    @Bindable var store: LLMSettingsStore
    let prices: [String: ModelPrice]
    let onSelectionChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(models, id: \.self) { model in
                        modelRow(model)
                    }
                }
                Section {
                    NavigationLink {
                        LLMReasoningEffortView(store: store, onSelectionChanged: onSelectionChanged)
                    } label: {
                        LabeledContent("エフォート", value: LLMReasoningEffort.label(for: store.reasoningEffort))
                    }
                }
            }
            .navigationTitle("モデルを選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("閉じる")
                }
            }
        }
    }

    private var models: [String] {
        store.availableModels.contains(store.model)
            ? store.availableModels
            : [store.model] + store.availableModels
    }

    private func modelRow(_ model: String) -> some View {
        Button {
            store.model = model
            LLMReasoningEffort.normalize(store)
            onSelectionChanged()
        } label: {
            HStack(spacing: 12) {
                Text(model).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let price = LLMPriceText.compact(model: model, prices: prices) {
                    Text(price)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if store.model == model {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
        }
    }
}

private enum LLMPriceText {
    static func compact(model: String, prices: [String: ModelPrice]) -> String? {
        guard let price = prices[model] else { return nil }
        return String(
            format: "$%.2f / $%.2f",
            price.inputCostPerToken * 1_000_000,
            price.outputCostPerToken * 1_000_000
        )
    }
}
