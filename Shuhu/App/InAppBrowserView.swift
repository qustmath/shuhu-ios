import SwiftUI
import WebKit

/// App 内浏览器（页内打开协议等页面）：标题跟随网页 title，页内历史可返回；
/// 非 http(s) 链接（mailto 等）交系统处理。与 Android 端 `WebViewScreen` 行为对应。
struct InAppBrowserView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var pageTitle = ""
    @State private var canGoBack = false

    var body: some View {
        NavigationStack {
            WebView(url: url, pageTitle: $pageTitle, canGoBack: $canGoBack)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(pageTitle.isEmpty ? "加载中…" : pageTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            NotificationCenter.default.post(name: .webviewGoBack, object: nil)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canGoBack)
                    }
                }
        }
    }
}

extension Notification.Name {
    static let webviewGoBack = Notification.Name("shufu.webview.goBack")
}

/// WKWebView 包装：回传页面 title 与后退能力；mailto 等外部 scheme 交系统。
struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var pageTitle: String
    @Binding var canGoBack: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        context.coordinator.webView = webView
        context.coordinator.goBackObserver = NotificationCenter.default.addObserver(
            forName: .webviewGoBack, object: nil, queue: .main,
        ) { _ in
            if webView.canGoBack {
                webView.goBack()
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        var webView: WKWebView?
        var goBackObserver: NSObjectProtocol?

        init(_ parent: WebView) {
            self.parent = parent
        }

        deinit {
            if let goBackObserver {
                NotificationCenter.default.removeObserver(goBackObserver)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.pageTitle = webView.title ?? ""
            parent.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.canGoBack = webView.canGoBack
        }

        /// http(s) 留在页内；mailto 等其它 scheme 交给系统处理。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
        ) {
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme != "http" && scheme != "https" {
                    decisionHandler(.cancel)
                    UIApplication.shared.open(url)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}
