import SwiftUI
import UIKit

/// 书架拖动排序的手势桥：把「长按起拖」做成宿主 `UIScrollView` 上的 `UILongPressGestureRecognizer`。
///
/// **为什么不用 SwiftUI 手势**（2026-09-21 实测）：
/// - 行上挂 `.gesture(...)`：子手势抢走 `ScrollView` 的 pan，整屏只有没挂手势的广告区能滑；
/// - 换成 `.simultaneousGesture(...)`：CI 的 XCUITest 实测**仍然不放开滚动**（滑了完全不动）；
/// - `.scrollDisabled` 那套补救还会和 pan 抢同一次触摸。
///
/// 所以行上**一个 SwiftUI 手势都不挂**——滚动不可能被抢。长按识别器挂在 ScrollView 上
/// （它见得到所有子视图的触摸），语义完全由我们定（与 Android `detectDragGesturesAfterLongPress` 同构）：
/// - 起点不在可拖书行 → `gestureRecognizerShouldBegin` 直接 false，识别器失败，滚动照旧；
/// - 手指滑动 → 先识别的是 pan，长按被取消 → 正常滚动；
/// - 手指原地按住 0.35s → 长按识别 → pan 再也无法识别 → 拖动期自然不滚动。
///
/// 坐标取「内容坐标系」（探针视图就是内容锚点），与滚动位置无关；拖动期布局又冻结，
/// 于是位移是手指位置的纯函数，不会被换位/动画污染。
struct ShelfReorderGesture: UIViewRepresentable {
    /// 起点是否落在可拖动的书行上（纯查询，不改状态）。
    let hitTest: (CGPoint) -> Bool
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let probe = ProbeView()
        probe.isUserInteractionEnabled = false // 只是坐标锚点，不参与命中
        probe.backgroundColor = .clear
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        context.coordinator.callbacks = self
        guard let probe = probe as? ProbeView else { return }
        probe.onAttached = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(to: view)
        }
    }

    /// 内容锚点：进窗口（父链完整）后再去挂识别器。
    final class ProbeView: UIView {
        var onAttached: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            onAttached?(self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var callbacks: ShelfReorderGesture?

        private weak var probe: UIView?
        private weak var recognizer: UILongPressGestureRecognizer?
        private var dragging = false

        func attach(to probe: UIView) {
            // 探针可能被 SwiftUI 重建：引用要跟着换（识别器只挂一次，挂在 ScrollView 上）
            self.probe = probe
            guard recognizer == nil else { return }
            guard let scrollView = probe.enclosingScrollView else { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumPressDuration = 0.35
            recognizer.allowableMovement = 10
            // 起拖后不再把触摸交给视图：长按松手不会误触发书行的点按（进详情页）
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let probe else { return }
            let point = recognizer.location(in: probe)
            switch recognizer.state {
            case .began:
                dragging = true
                callbacks?.onBegan(point)
            case .changed:
                if dragging { callbacks?.onMoved(point) }
            case .ended, .cancelled, .failed:
                guard dragging else { return }
                dragging = false
                callbacks?.onFinished()
            default:
                break
            }
        }

        // 起点不在可拖书行 → 不识别，pan 照常滚动
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let probe else { return false }
            return callbacks?.hitTest(recognizer.location(in: probe)) ?? false
        }

        // 与 ScrollView 的 pan 不同时识别：谁先识别谁赢。
        // 先动 = 滚动（长按随后被取消）；先按住 = 拖动（pan 再也起不来，拖动期不滚动）。
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer,
        ) -> Bool {
            false
        }
    }
}

private extension UIView {
    /// 最近的祖先 UIScrollView（SwiftUI 的 ScrollView 底下就是它）。
    var enclosingScrollView: UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}
