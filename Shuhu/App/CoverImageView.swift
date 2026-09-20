import SwiftUI

/// 封面图组件（odui 版）：path 为 nil 时降级为「书脊排印」占位（左缘墨线 + 竖排书名），
/// 让没封面的书也像书架上的一员；支持本地沙盒路径与 http(s) URL（同步来的封面是完整 URL），
/// 加载中/失败显示发丝线底色。
/// 三处复用：主页书行 62×90、详情页头部 96×140、表单预览 84×122。
struct CoverImageView: View {
    let path: String?
    /// 无封面时书脊上的竖排书名。
    var title: String = ""
    var width: CGFloat = 62
    var height: CGFloat = 90
    var cornerRadius: CGFloat = 3

    @State private var localImage: UIImage?

    var body: some View {
        ZStack {
            if path == nil {
                BookSpine(title: title)
            } else if let path, let url = Self.remoteURL(path) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        loadingPlaceholder
                    }
                }
            } else if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else {
                loadingPlaceholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            localImage = Self.loadLocalImage(path)
        }
    }

    /// 加载中/失败占位：发丝线底色（Android placeholder/error = Hairline）。
    private var loadingPlaceholder: some View {
        Rectangle().fill(Paper.hairline)
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
