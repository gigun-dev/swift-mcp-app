import SwiftUI
import UIKit

/// ユーザー吹き出しをその場で標準テキスト選択へ切り替える。
///
/// 通常時の `Text` は選択中も透明なままレイアウトに残すため、UITextViewへ切り替えても
/// 吹き出しの位置・改行・大きさが変わらない。選択中に外側をタップするか選択を解除すると
/// 通常表示へ戻る。
struct SelectableUserBubble: View {
    let text: String
    let canEdit: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void

    @State private var isSelecting = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.white)
            .opacity(isSelecting ? 0 : 1)
            .accessibilityHidden(isSelecting)
            .overlay {
                if isSelecting {
                    InlineTextSelectionView(text: text) {
                        isSelecting = false
                    }
                    .accessibilityLabel(text)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.accentColor)
            )
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
            .contextMenu {
                Button("コピー", systemImage: "doc.on.doc", action: onCopy)
                Button("選択", systemImage: "selection.pin.in.out") {
                    // context menuを閉じた次のrun loopでfirst responderを切り替える。
                    DispatchQueue.main.async { isSelecting = true }
                }
                Button("編集", systemImage: "pencil", action: onEdit)
                    .disabled(!canEdit)
            }
            // contextMenuをこの外側のframeより前に置く。previewへ透明な整列領域を含めない。
            .frame(maxWidth: 300, alignment: .trailing)
    }
}

/// iOS標準の青い選択ハンドルと編集メニューを、元の吹き出し内で開始する。
private struct InlineTextSelectionView: UIViewRepresentable {
    let text: String
    let onSelectionEnded: () -> Void

    func makeUIView(context: Context) -> AutoSelectingTextView {
        let textView = AutoSelectingTextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .callout)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .white
        textView.tintColor = .white
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.onSelectionEnded = onSelectionEnded
        return textView
    }

    func updateUIView(_ textView: AutoSelectingTextView, context: Context) {
        textView.onSelectionEnded = onSelectionEnded
        guard textView.text != text else { return }
        textView.text = text
        textView.hasPresentedInitialSelection = false
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AutoSelectingTextView,
        context: Context
    ) -> CGSize? {
        // overlay元のTextが決めた寸法へ厳密に合わせる。UITextViewのintrinsicContentSizeを
        // 採ると一行の自然幅が優先され、複数行の吹き出しから右へはみ出してしまう。
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class AutoSelectingTextView: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var onSelectionEnded: (() -> Void)?
    var hasPresentedInitialSelection = false
    private weak var observedWindow: UIWindow?
    private lazy var outsideTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(windowTapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observedWindow?.removeGestureRecognizer(outsideTapRecognizer)
        observedWindow = window
        window?.addGestureRecognizer(outsideTapRecognizer)
        delegate = self
        presentInitialSelection()
    }

    deinit {
        observedWindow?.removeGestureRecognizer(outsideTapRecognizer)
    }

    func presentInitialSelection() {
        guard window != nil, !hasPresentedInitialSelection, !text.isEmpty else { return }
        hasPresentedInitialSelection = true
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: (text as NSString).length)

        // responder登録・選択rect・context menu終了が確定した次のrun loopで標準編集メニューを出す。
        DispatchQueue.main.async { [weak self] in
            guard let self, let selectedTextRange else { return }
            UIMenuController.shared.showMenu(from: self, rect: firstRect(for: selectedTextRange))
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard hasPresentedInitialSelection, textView.selectedRange.length == 0 else { return }
        finishSelection()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard hasPresentedInitialSelection else { return }
        finishSelection()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func windowTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard !bounds.contains(point) else { return }
        finishSelection()
    }

    private func finishSelection() {
        guard hasPresentedInitialSelection else { return }
        hasPresentedInitialSelection = false
        let completion = onSelectionEnded
        onSelectionEnded = nil
        observedWindow?.removeGestureRecognizer(outsideTapRecognizer)
        _ = resignFirstResponder()
        completion?()
    }
}
