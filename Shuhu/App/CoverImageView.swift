import SwiftUI

/// 封面图组件：支持本地沙盒路径与 http(s) URL（同步来的封面是服务端引用的完整 URL）。
/// 路径为空或加载失败时优雅降级为占位样式，不崩溃（票据 07）。
/// 三处复用：主页卡片 58×78、详情页头部 92×124、表单预览。
struct CoverImageView: View {
    let path: String?
    var width: CGFloat = 58
    var height: CGFloat = 78

    @State private var localImage: UIImage?

    var body: some View {
        ZStack {
            if let path, let url = Self.remoteURL(path) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            localImage = Self.loadLocalImage(path)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.purple.opacity(0.12))
            .overlay(
                Text("书")
                    .font(.title3)
                    .foregroundStyle(.purple.opacity(0.6)),
            )
    }

    private static func remoteURL(_ path: String) -> URL? {
        guard path.hasPrefix("http://") || path.hasPrefix("https://") else { return nil }
        return URL(string: path)
    }

    private static func loadLocalImage(_ path: String?) -> UIImage? {
        guard let path, !path.isEmpty, !path.hasPrefix("http") else { return nil }
        return UIImage(contentsOfFile: path)
    }
}
