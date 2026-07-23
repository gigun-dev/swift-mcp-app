// ChatHomeView の drawer gesture 配線。画面構成本体から分離し、open/closeの3入力面が
// 同じ committed/live state をどう共有するかをこのファイルだけで追えるようにする。
import SwiftUI
import Kernel

enum SidebarGestureSource {
    case chatPane
    case sidebarPane
    case exposedMain
}

extension ChatHomeView {
    /// committed offset と live translation の和を物理範囲へ収める。open は0から右へ、closeは
    /// revealWidthから左へ0へ戻るため、指とcardの移動方向が常に一致する。
    func sidebarOffset(revealWidth: CGFloat) -> CGFloat {
        let committed: CGFloat = showingSidebar ? revealWidth : 0
        return min(max(committed + sidebarDragTranslation, 0), revealWidth)
    }

    /// 閉じたchat paneの右drag。開始Yが現在のMCP App frame帯なら、そのgesture中は永続的に拒否する。
    func chatPaneOpenGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !showingSidebar else { return }
                if activeSidebarGesture == nil { activeSidebarGesture = .chatPane }
                guard activeSidebarGesture == .chatPane else { return }
                if openGestureAllowed == nil {
                    let bands = mcpAppFrames.map { Double($0.minY) ... Double($0.maxY) }
                    openGestureAllowed = SidebarGesturePolicy.canStartOpen(
                        atY: Double(value.startLocation.y),
                        excludedVerticalBands: bands
                    )
                }
                guard openGestureAllowed == true else {
                    sidebarDragTranslation = 0
                    return
                }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    intent: .open
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .chatPane else { return }
                let reachedTarget = openGestureAllowed == true && SidebarGesturePolicy.commits(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    predictedHorizontal: Double(value.predictedEndTranslation.width),
                    revealWidth: Double(revealWidth),
                    intent: .open
                )
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    showingSidebar = reachedTarget
                    sidebarDragTranslation = 0
                }
                activeSidebarGesture = nil
                openGestureAllowed = nil
            }
    }

    /// sidebarのどこからでも左dragで閉じる。simultaneousでListの縦scrollを残し、pure policyが
    /// 横優位かつ左向きのときだけmain cardを指追従させる。
    func sidebarPaneCloseGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard showingSidebar else { return }
                if activeSidebarGesture == nil { activeSidebarGesture = .sidebarPane }
                guard activeSidebarGesture == .sidebarPane else { return }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    intent: .close
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .sidebarPane else { return }
                settleCloseDrag(
                    horizontal: value.translation.width,
                    vertical: value.translation.height,
                    predictedHorizontal: value.predictedEndTranslation.width,
                    revealWidth: revealWidth
                )
                activeSidebarGesture = nil
            }
    }

    /// 露出mainはtapとleft-dragを1本のrecognizerで排他する。小移動はtap close、8ptを超えた
    /// 移動は十分なleft-dragだけcloseになり、drag終了後に別tapが追撃しない。
    func exposedMainCloseGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard showingSidebar else { return }
                if activeSidebarGesture == nil { activeSidebarGesture = .exposedMain }
                guard activeSidebarGesture == .exposedMain else { return }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    intent: .close
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .exposedMain else { return }
                let resolution = SidebarGesturePolicy.resolveExposedMain(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    predictedHorizontal: Double(value.predictedEndTranslation.width),
                    revealWidth: Double(revealWidth)
                )
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    showingSidebar = resolution != .close
                    sidebarDragTranslation = 0
                }
                activeSidebarGesture = nil
            }
    }

    private func settleCloseDrag(
        horizontal: CGFloat,
        vertical: CGFloat,
        predictedHorizontal: CGFloat,
        revealWidth: CGFloat
    ) {
        let reachedTarget = SidebarGesturePolicy.commits(
            horizontal: Double(horizontal),
            vertical: Double(vertical),
            predictedHorizontal: Double(predictedHorizontal),
            revealWidth: Double(revealWidth),
            intent: .close
        )
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
            showingSidebar = !reachedTarget
            sidebarDragTranslation = 0
        }
    }
}
