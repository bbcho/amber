import AppKit
import WebKit

enum MermaidOutcome {
    case image(NSImage)
    case failure(String)
}

/// A draw that ended in a result worth remembering, or in a failure that a retry may cure.
private enum Drawing {
    case settled(MermaidOutcome)
    case transient(String)
}

/// Draws Mermaid diagrams offline in an invisible web view, one at a time, and remembers each
/// result by its source.
@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()

    private(set) var drawCount = 0
    private var outcomes: [String: MermaidOutcome] = [:]
    private var running: [String: Task<MermaidOutcome, Never>] = [:]
    private var queue: Task<Void, Never>?
    private var page: MermaidWebPage
    private let drawScript: String
    private let timeout: TimeInterval

    static let timeoutMessage = "Diagram took too long to render"
    static let defaultDrawScript = "return await amberRender(id, source)"

    /// `drawScript` is a test seam: the async function body that draws `source` as `id`.
    init(timeout: TimeInterval = 10, drawScript: String = MermaidRenderer.defaultDrawScript) {
        self.timeout = timeout
        self.drawScript = drawScript
        page = MermaidWebPage(drawScript: drawScript)
        watchForTermination()
    }

    private func watchForTermination() {
        page.onTermination = { [weak self] stopped in
            guard let self, self.page === stopped else { return }
            self.replacePage()
        }
    }

    private func replacePage() {
        page.tearDown()
        page = MermaidWebPage(drawScript: drawScript)
        watchForTermination()
    }

    func cachedOutcome(for source: String) -> MermaidOutcome? { outcomes[source] }

    func render(_ source: String) async -> MermaidOutcome {
        if let known = outcomes[source] { return known }
        if let task = running[source] { return await task.value }
        let previous = queue
        let task = Task { () -> MermaidOutcome in
            await previous?.value
            drawCount += 1
            let outcome: MermaidOutcome
            let drawing = await drawWithinTimeout(source, id: "amber-\(drawCount)")
                ?? .transient(Self.timeoutMessage)
            switch drawing {
            case .settled(let settled):
                outcome = settled
                outcomes[source] = settled
            case .transient(let message):
                replacePage()
                outcome = .failure(message)
            }
            running[source] = nil
            return outcome
        }
        running[source] = task
        queue = Task { _ = await task.value }
        return await task.value
    }

    /// Nil when the draw is still running after `timeout`.
    private func drawWithinTimeout(_ source: String, id: String) async -> Drawing? {
        let stuckPage = page
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish = { (outcome: Drawing?) in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: outcome)
            }
            Task { finish(await stuckPage.draw(source, id: id)) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                finish(nil)
            }
        }
    }

    /// Runs `script` as an async function body in the rendering page.
    func probe(_ script: String) async -> Any? {
        await page.run(script)
    }
}

@MainActor
private final class MermaidWebPage: NSObject, WKNavigationDelegate {
    var onTermination: ((MermaidWebPage) -> Void)?
    private var allowsOneNavigation = true
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private var loading: CheckedContinuation<Void, Never>?
    private let drawScript: String

    init(drawScript: String) {
        self.drawScript = drawScript
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func draw(_ source: String, id: String) async -> Drawing {
        await load()
        let reply = await run(drawScript, ["id": id, "source": source])
        guard let result = reply as? [String: Any] else {
            return .transient("Mermaid did not respond")
        }
        guard result["ok"] as? Bool == true,
              let width = result["width"] as? Double, let height = result["height"] as? Double
        else { return .settled(.failure(result["message"] as? String ?? "Mermaid failed")) }
        return await image(width: width, height: height)
    }

    /// Stops the page's scripts and drops what it holds, so a looping script cannot keep it.
    func tearDown() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
        finishLoading()
    }

    func run(_ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
        await load()
        return try? await webView.callAsyncJavaScript(
            script, arguments: arguments, contentWorld: .page
        )
    }

    private func image(width: Double, height: Double) async -> Drawing {
        webView.frame.size = NSSize(width: ceil(width), height: ceil(height))
        _ = await run("return 0")
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let data = try? await webView.pdf(configuration: configuration),
              let image = NSImage(data: data) else {
            return .transient("Could not draw the diagram")
        }
        return .settled(.image(image))
    }

    private func load() async { await loaded.value }

    private lazy var loaded = Task {
        await withCheckedContinuation { continuation in
            loading = continuation
            let script = MermaidPage.resourceDirectory()
                .appendingPathComponent(MermaidPage.scriptName)
            if let source = try? String(contentsOf: script, encoding: .utf8) {
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: source, injectionTime: .atDocumentStart,
                                 forMainFrameOnly: true)
                )
            }
            webView.loadHTMLString(MermaidPage.html, baseURL: nil)
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard allowsOneNavigation else { return .cancel }
        allowsOneNavigation = false
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading()
        onTermination?(self)
    }

    private func finishLoading() {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading()
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        finishLoading()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading()
    }
}
