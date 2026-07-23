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
        // 2026-07-23 drawer 残振動の修正(第2根因): translation/startLocation は既定の .local(=このドラッグで
        // 動くビュー自身の空間)で測ってはいけない。offset 適用 → 空間移動 → 次フレームの translation が縮む
        // → offset が戻る、のフィードバックで境界が2周期振動する。offset の外側に置いた不動の named 空間で測る。
        DragGesture(minimumDistance: 12, coordinateSpace: .named(MCPAppGestureCoordinateSpace.name))
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
                // minimumDistance=12 到達済みなので初回 onChanged で軸をロックする(以後固定)。
                if sidebarDragAxis == nil {
                    sidebarDragAxis = SidebarGesturePolicy.lockAxis(
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height)
                    )
                }
                // 縦ロックなら translation を据え置き(0 のまま)、drawer を追従させない。
                guard sidebarDragAxis == .horizontal else { return }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    intent: .open
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .chatPane else { return }
                // 横ロックした gesture だけが commit 判定に到達する(縦ロックは追従していない)。
                let reachedTarget = openGestureAllowed == true
                    && sidebarDragAxis == .horizontal
                    && SidebarGesturePolicy.commits(
                        horizontal: Double(value.translation.width),
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
                sidebarDragAxis = nil
            }
    }

    /// sidebarのどこからでも左dragで閉じる。simultaneousでListの縦scrollを残し、pure policyが
    /// 横優位かつ左向きのときだけmain cardを指追従させる。
    func sidebarPaneCloseGesture(revealWidth: CGFloat) -> some Gesture {
        // 2026-07-23 drawer 残振動の修正(第2根因・chatPaneOpenGesture と同じ理由): offset の外側の不動空間で測る。
        DragGesture(minimumDistance: 12, coordinateSpace: .named(MCPAppGestureCoordinateSpace.name))
            .onChanged { value in
                guard showingSidebar else { return }
                if activeSidebarGesture == nil { activeSidebarGesture = .sidebarPane }
                guard activeSidebarGesture == .sidebarPane else { return }
                // minimumDistance=12 到達済みなので初回 onChanged で軸をロックする(以後固定)。
                if sidebarDragAxis == nil {
                    sidebarDragAxis = SidebarGesturePolicy.lockAxis(
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height)
                    )
                }
                // 縦ロックなら List の縦scroll に譲り、main card は据え置く。
                guard sidebarDragAxis == .horizontal else { return }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    intent: .close
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .sidebarPane else { return }
                settleCloseDrag(
                    horizontal: value.translation.width,
                    predictedHorizontal: value.predictedEndTranslation.width,
                    revealWidth: revealWidth,
                    axis: sidebarDragAxis
                )
                activeSidebarGesture = nil
                sidebarDragAxis = nil
            }
    }

    /// 露出mainはtapとleft-dragを1本のrecognizerで排他する。小移動はtap close、8ptを超えた
    /// 移動は十分なleft-dragだけcloseになり、drag終了後に別tapが追撃しない。
    func exposedMainCloseGesture(revealWidth: CGFloat) -> some Gesture {
        // 2026-07-23 drawer 残振動の修正(第2根因・chatPaneOpenGesture と同じ理由): offset の外側の不動空間で測る。
        // tapSlop(8pt)判定も同じ空間の translation を使うので、tap/close 分類の閾値は空間移動の影響を受けない。
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MCPAppGestureCoordinateSpace.name))
            .onChanged { value in
                guard showingSidebar else { return }
                if activeSidebarGesture == nil { activeSidebarGesture = .exposedMain }
                guard activeSidebarGesture == .exposedMain else { return }
                // minimumDistance=0 なので tap 兼用。tapSlop(8pt)以内はまだ tap かもしれず軸を決めない。
                // 累積が slop を初めて超えたフレームで一度だけロックする(tap→close の既存挙動を壊さない)。
                let magnitudeSquared = Double(value.translation.width * value.translation.width
                    + value.translation.height * value.translation.height)
                if sidebarDragAxis == nil, magnitudeSquared > exposedMainTapSlop * exposedMainTapSlop {
                    sidebarDragAxis = SidebarGesturePolicy.lockAxis(
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height)
                    )
                }
                // slop 未満(軸未ロック)や縦ロックは追従させない。tap 判定は onEnded の resolve が担う。
                guard sidebarDragAxis == .horizontal else { return }
                sidebarDragTranslation = CGFloat(SidebarGesturePolicy.liveTranslation(
                    horizontal: Double(value.translation.width),
                    intent: .close
                ))
            }
            .onEnded { value in
                guard activeSidebarGesture == .exposedMain else { return }
                let resolution = SidebarGesturePolicy.resolveExposedMain(
                    horizontal: Double(value.translation.width),
                    vertical: Double(value.translation.height),
                    predictedHorizontal: Double(value.predictedEndTranslation.width),
                    revealWidth: Double(revealWidth),
                    lockedAxis: sidebarDragAxis,
                    tapSlop: exposedMainTapSlop
                )
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                    showingSidebar = resolution != .close
                    sidebarDragTranslation = 0
                }
                activeSidebarGesture = nil
                sidebarDragAxis = nil
            }
    }

    // exposedMain の tap/drag 境界。onChanged の軸ロック閾値と resolveExposedMain の tapSlop を
    // 同じ値に揃え、live 追従と onEnded 判定の食い違いを防ぐ(policy 既定と同じ 8pt)。
    private var exposedMainTapSlop: Double { 8 }

    private func settleCloseDrag(
        horizontal: CGFloat,
        predictedHorizontal: CGFloat,
        revealWidth: CGFloat,
        axis: SidebarGesturePolicy.Axis?
    ) {
        // 横ロックした close drag だけ commit 判定へ。縦ロックはそのまま開いたまま残す。
        let reachedTarget = axis == .horizontal && SidebarGesturePolicy.commits(
            horizontal: Double(horizontal),
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
