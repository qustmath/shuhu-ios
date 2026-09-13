import SwiftUI

/// 封面图组件：按路径读沙盒文件；路径为空或文件丢失时优雅降级为占位样式，不崩溃（票据 07）。
/// 三处复用：主页卡片 58×78、详情页头部 92×124、表单预览。
struct CoverImageView: View {
    let path: String?
    var width: CGFloat = 58
    var height: CGFloat = 78

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.purple.opacity(0.12))
                    .overlay(
                        Text("书")
                            .font(.title3)
                            .foregroundStyle(.purple.opacity(0.6)),
                    )
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            image = Self.loadImage(path)
        }
    }

    private static func loadImage(_ path: String?) -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: path)
    }
}
