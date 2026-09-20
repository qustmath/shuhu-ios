import SwiftUI

/// 书乎 logo（首页标题左侧）：纸底圆角方 + 开卷 + 赭红书签——
/// 与 Android `res/drawable/ic_logo_mark.xml`（1024 viewport）逐路径对应。
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 1024
            context.scaleBy(x: scale, y: scale)

            // 纸底圆角方
            var paper = Path()
            paper.move(to: CGPoint(x: 225, y: 0))
            paper.addLine(to: CGPoint(x: 799, y: 0))
            paper.addQuadCurve(to: CGPoint(x: 1024, y: 225), control: CGPoint(x: 1024, y: 0))
            paper.addLine(to: CGPoint(x: 1024, y: 799))
            paper.addQuadCurve(to: CGPoint(x: 799, y: 1024), control: CGPoint(x: 1024, y: 1024))
            paper.addLine(to: CGPoint(x: 225, y: 1024))
            paper.addQuadCurve(to: CGPoint(x: 0, y: 799), control: CGPoint(x: 0, y: 1024))
            paper.addLine(to: CGPoint(x: 0, y: 225))
            paper.addQuadCurve(to: CGPoint(x: 225, y: 0), control: CGPoint(x: 0, y: 0))
            paper.closeSubpath()
            context.fill(paper, with: .color(Color(red: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255)))

            let ink = Color(red: 0x2E / 255, green: 0x2A / 255, blue: 0x25 / 255)
            let stroke = StrokeStyle(lineWidth: 56, lineCap: .round, lineJoin: .round)

            // 开卷左页
            var left = Path()
            left.move(to: CGPoint(x: 512, y: 310))
            left.addCurve(
                to: CGPoint(x: 218, y: 260),
                control1: CGPoint(x: 430, y: 248), control2: CGPoint(x: 300, y: 238),
            )
            left.addLine(to: CGPoint(x: 218, y: 700))
            left.addQuadCurve(to: CGPoint(x: 265, y: 723), control: CGPoint(x: 218, y: 729))
            left.addCurve(
                to: CGPoint(x: 500, y: 764),
                control1: CGPoint(x: 339, y: 714), control2: CGPoint(x: 426, y: 726),
            )
            context.stroke(left, with: .color(ink), style: stroke)

            // 开卷右页
            var right = Path()
            right.move(to: CGPoint(x: 512, y: 310))
            right.addCurve(
                to: CGPoint(x: 806, y: 260),
                control1: CGPoint(x: 594, y: 248), control2: CGPoint(x: 724, y: 238),
            )
            right.addLine(to: CGPoint(x: 806, y: 700))
            right.addQuadCurve(to: CGPoint(x: 759, y: 723), control: CGPoint(x: 806, y: 729))
            right.addCurve(
                to: CGPoint(x: 524, y: 764),
                control1: CGPoint(x: 685, y: 714), control2: CGPoint(x: 598, y: 726),
            )
            context.stroke(right, with: .color(ink), style: stroke)

            // 中缝底端
            var mid = Path()
            mid.move(to: CGPoint(x: 500, y: 764))
            mid.addLine(to: CGPoint(x: 524, y: 764))
            context.stroke(mid, with: .color(ink), style: stroke)

            // 中缝
            var spine = Path()
            spine.move(to: CGPoint(x: 512, y: 310))
            spine.addLine(to: CGPoint(x: 512, y: 764))
            context.stroke(spine, with: .color(ink), style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))

            // 赭红书签
            var bookmark = Path()
            bookmark.move(to: CGPoint(x: 616, y: 256))
            bookmark.addLine(to: CGPoint(x: 704, y: 256))
            bookmark.addLine(to: CGPoint(x: 704, y: 530))
            bookmark.addLine(to: CGPoint(x: 660, y: 494))
            bookmark.addLine(to: CGPoint(x: 616, y: 530))
            bookmark.closeSubpath()
            context.fill(bookmark, with: .color(Color(red: 0xA4 / 255, green: 0x57 / 255, blue: 0x3F / 255)))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("书乎")
    }
}
