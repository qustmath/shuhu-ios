import CoreGraphics

/// 主页拖动换位的纯逻辑（无 SwiftUI 依赖，可单测）。
///
/// 设计要点（2026-09-21 重做，修「拖动排序时两本书来回交替晃动」）：
/// 拖动期**布局冻结**——换位不改列表布局，只把各行渲染到别的槽位（`offset`）；被拖行的 `offset`
/// 就是手指位移本身，不再做「换位后把位移补偿掉」的累减。于是判定只依赖两个数：
/// 手指相对拖动起始槽位的**绝对位移** + 上一次的目标槽位（滞回状态）。
///
/// 旧实现（每换一位就 `dragOffsetY -= step`，且真的改布局）会自激振荡：SwiftUI 的
/// `DragGesture.translation` 在行的局部坐标系里测量，行一旦换槽位/换动画，坐标系就跟着动，
/// 位移随之被污染（手指停着不动，位移自己会跑），于是同一对行以每秒十余次来回翻转。
/// 现在位移不会自己变，且同一 (当前槽位, 位移) 必得同一结果，手指不动就绝不可能换位。
enum HomeReorder {

    /// 各显示槽位的中线（下标 = 显示序）。广告固定占一个槽位（书 ≥ 2 本时插在第 3 个显示位）。
    static func slotMids(
        bookCount: Int,
        bookRowHeight: CGFloat,
        adHeight: CGFloat,
        hasAd: Bool,
    ) -> [CGFloat] {
        var heights = Array(repeating: bookRowHeight, count: max(bookCount, 0))
        if hasAd, !heights.isEmpty {
            heights.insert(adHeight, at: min(2, heights.count))
        }
        var mids: [CGFloat] = []
        mids.reserveCapacity(heights.count)
        var top: CGFloat = 0
        for height in heights {
            mids.append(top + height / 2)
            top += height
        }
        return mids
    }

    /// 书下标 → 槽位下标（广告占掉一个槽位，故其后的书都往后错一位）。
    static func slotOfBook(_ bookIndex: Int, bookCount: Int, hasAd: Bool) -> Int {
        guard hasAd, bookCount > 0 else { return bookIndex }
        return bookIndex >= min(2, bookCount) ? bookIndex + 1 : bookIndex
    }

    /// 目标书下标。`current` 是当前目标（滞回状态），`offsetY` 是相对拖动起始槽位的手指位移。
    ///
    /// 阈值 = 相邻两槽位中线的中点，正反向各让出 `hysteresis`：越过「中点 + H」才换过去，
    /// 要换回来得越过「中点 − H」，于是指尖 ±1~2pt 的抖动不可能把同一对行来回翻转。
    /// 广告槽位比书行高，跨广告时步长自动变成「广告高 / 2 + 书行高 / 2」（与 Android 实测步长一致）。
    static func targetBookIndex(
        current: Int,
        fromBookIndex: Int,
        bookCount: Int,
        mids: [CGFloat],
        hasAd: Bool,
        offsetY: CGFloat,
        hysteresis: CGFloat,
    ) -> Int {
        guard bookCount > 1 else { return 0 }
        func mid(_ bookIndex: Int) -> CGFloat {
            let slot = slotOfBook(bookIndex, bookCount: bookCount, hasAd: hasAd)
            return slot < mids.count ? mids[slot] : 0
        }
        // 手指位置 = 起始槽位中线 + 绝对位移（与当前排到第几位无关，故不会被换位本身影响）
        let center = mid(fromBookIndex) + offsetY
        var target = min(max(current, 0), bookCount - 1)
        while target < bookCount - 1, center > (mid(target) + mid(target + 1)) / 2 + hysteresis {
            target += 1
        }
        while target > 0, center < (mid(target) + mid(target - 1)) / 2 - hysteresis {
            target -= 1
        }
        return target
    }

    /// 把 `from` 处的元素移到 `to`（拖动期的视觉顺序 = 松手要提交的顺序）。
    static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var copy = items
        let element = copy.remove(at: from)
        copy.insert(element, at: to)
        return copy
    }
}
