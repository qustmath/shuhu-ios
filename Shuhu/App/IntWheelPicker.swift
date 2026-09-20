import SwiftUI

/// 纵向滚动选择器（odui 版，对齐 Android `IntWheelPicker`）：
/// 页码沿中轴水平居中；字号/颜色随到中心的距离连续渐变——正中最大且赭红加粗，离开时变小变灰。
/// 受控组件：外部改 value（如「读完」）滚动到对应项，滚动停止把居中项回写 value。
struct IntWheelPicker: View {
    let values: [Int]
    @Binding var value: Int
    var visibleCount = 3
    var itemHeight: CGFloat = 44

    /// 视口正中项（scrollTargetBehavior 对齐后即选中值）。
    @State private var centered: Int?

    /// 选中项字号（pt）；相邻项按比例缩到最小。
    private let maxFontSize: CGFloat = 26
    private let minScale: CGFloat = 14.0 / 26.0

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(values, id: \.self) { item in
                    Text("\(item)")
                        .font(.system(size: maxFontSize, weight: centered == item ? .bold : .regular))
                        .foregroundStyle(centered == item ? Paper.ochre : Paper.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: itemHeight)
                        .scrollTransition(.interactive) { content, phase in
                            // phase.value：0 = 正中，±1 = 恰好离开一屏；连续缩放模拟字号渐变
                            content.scaleEffect(1 - (1 - minScale) * min(abs(phase.value), 1))
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centered, anchor: .center)
        // 首尾各 pad 个行高的边距，保证第一项/最后一项也能对齐到视口正中
        .contentMargins(.vertical, itemHeight * CGFloat(visibleCount / 2), for: .scrollContent)
        .frame(height: itemHeight * CGFloat(visibleCount))
        .scrollIndicators(.hidden)
        .onAppear { centered = value }
        .onChange(of: centered) { _, new in
            if let new, values.contains(new), new != value {
                value = new
            }
        }
        .onChange(of: value) { _, new in
            // 外部改值（如「读完」）→ 滚到对应项
            if new != centered, values.contains(new) {
                withAnimation { centered = new }
            }
        }
    }
}
