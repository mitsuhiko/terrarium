import SwiftUI
import UIKit
import WebKit

// The Python documentation viewer (D37): the bundled HTML docs of a Python
// version in a web view, with native search over the docs index
// (DocsIndex), back/forward and a version switch. It is presented with UIKit
// on top of whatever is on screen (the agent's sheet included), so a help()
// in the console, Show Info and the agent can all open it.

struct DocsTarget: Equatable {
    var version: String
    var ref: String? // nil: the docs' start page
}

@MainActor @Observable
final class DocsBrowser: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    private(set) var version: String
    private(set) var title = "Python Docs"
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The page shown (for the self-test): "library/json.html#json.loads".
    private(set) var ref: String?
    var query = ""
    private(set) var results: [DocsIndex.Hit] = []
    private(set) var searching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(schemeHandler: AppSchemeHandler, target: DocsTarget) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        version = target.version
        super.init()
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] web, _ in Task { @MainActor in self?.canGoBack = web.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] web, _ in Task { @MainActor in self?.canGoForward = web.canGoForward } },
            webView.observe(\.title) { [weak self] web, _ in Task { @MainActor in self?.titleChanged(web.title) } },
            webView.observe(\.url) { [weak self] web, _ in Task { @MainActor in self?.urlChanged(web.url) } },
        ]
        open(target)
    }

    func open(_ target: DocsTarget) {
        version = target.version
        query = ""
        results = []
        webView.load(URLRequest(url: DocsIndex.url(target.version, ref: target.ref ?? "index.html")))
    }

    /// The same page in another version, if it has it (else its start page).
    func switchVersion(_ to: String) {
        guard to != version else { return }
        let page = ref?.split(separator: "#").first.map(String.init)
        let exists = page.map { FileManager.default.fileExists(atPath: DocsIndex.htmlRoot(to).appendingPathComponent($0).path) } ?? false
        open(DocsTarget(version: to, ref: exists ? ref : nil))
    }

    private func titleChanged(_ raw: String?) {
        // "json — JSON encoder and decoder — Python 3.14.8 documentation"
        guard let raw, !raw.isEmpty else { return }
        title = raw.components(separatedBy: " \u{2014} Python ").first ?? raw
    }

    private func urlChanged(_ url: URL?) {
        guard let url, url.scheme == AppSchemeHandler.scheme else { return }
        let prefix = "/docs/\(version)/"
        guard url.path.hasPrefix(prefix) else { return }
        ref = String(url.path.dropFirst(prefix.count)) + (url.fragment.map { "#\($0)" } ?? "")
    }

    func search(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        let version = version
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let hits = await DocsIndex.shared.search(q, version: version, limit: 40)
            guard !Task.isCancelled else { return }
            results = hits
            searching = false
        }
    }

    func show(_ hit: DocsIndex.Hit) {
        query = ""
        results = []
        webView.load(URLRequest(url: DocsIndex.url(version, ref: hit.ref)))
    }

    // Links out of the docs (python.org, PEPs, GitHub) open in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == AppSchemeHandler.scheme || url.scheme == "about" { return .allow }
        if action.navigationType == .linkActivated { await UIApplication.shared.open(url) }
        return .cancel
    }
}

struct DocsView: View {
    @Bindable var browser: DocsBrowser
    var close: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                WebViewHost(webView: browser.webView)
                    .ignoresSafeArea(edges: .bottom)
                if !browser.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    results
                }
            }
            .navigationTitle(browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $browser.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Python \(browser.version)")
            .onChange(of: browser.query) { _, q in browser.search(q) }
            .onSubmit(of: .search) { if let first = browser.results.first { browser.show(first) } }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!browser.canGoBack)
                        .accessibilityLabel("Back")
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!browser.canGoForward)
                        .accessibilityLabel("Forward")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button { browser.open(DocsTarget(version: browser.version, ref: nil)) } label: { Label("Start Page", systemImage: "house") }
                        Button { browser.open(DocsTarget(version: browser.version, ref: "terrarium/index.html")) } label: { Label("Terrarium Modules", systemImage: "iphone") }
                        Button { browser.open(DocsTarget(version: browser.version, ref: "py-modindex.html")) } label: { Label("Module Index", systemImage: "list.bullet") }
                        Button { browser.open(DocsTarget(version: browser.version, ref: "tutorial/index.html")) } label: { Label("Tutorial", systemImage: "graduationcap") }
                        Picker("Version", selection: Binding(get: { browser.version }, set: { browser.switchVersion($0) })) {
                            ForEach(Runtimes.all, id: \.python) { Text($0.label).tag($0.python) }
                        }
                    } label: {
                        Image(systemName: "book")
                    }
                    .accessibilityLabel("Documentation menu")
                    Button("Done", action: close)
                }
            }
        }
    }

    private var results: some View {
        List {
            if browser.results.isEmpty {
                Text(browser.searching ? "Searching…" : "No results").foregroundStyle(.secondary)
            }
            ForEach(Array(browser.results.enumerated()), id: \.offset) { _, hit in
                Button { browser.show(hit) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(hit.kind).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(hit.title).font(["section", "module", "term"].contains(hit.kind) ? .body : .body.monospaced()).lineLimit(2)
                        }
                        if !hit.breadcrumb.isEmpty {
                            Text(hit.breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .tint(.primary)
            }
        }
        .listStyle(.plain)
        .background(Color(.systemBackground))
    }
}

/// Presents the viewer over everything else and keeps it while it is open.
@MainActor
final class DocsPresenter {
    private weak var controller: UIViewController?
    private(set) var browser: DocsBrowser?

    var isShown: Bool { controller?.view.window != nil && controller?.isBeingDismissed == false }

    func show(_ target: DocsTarget, schemeHandler: AppSchemeHandler, from presenter: @escaping () -> UIViewController?, attempt: Int = 0) {
        if isShown, let browser {
            browser.open(target)
            return
        }
        // A sheet that is still coming or going (the viewer closed a moment ago) can't present: wait for it.
        if let busy = presenter(), busy.isBeingDismissed || busy.isBeingPresented, attempt < 20 {
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                show(target, schemeHandler: schemeHandler, from: presenter, attempt: attempt + 1)
            }
            return
        }
        guard let presenter = presenter() else {
            WebHost.appendDocument(".probe-log.txt", "[docs] nothing to present from\n")
            return
        }
        let browser = DocsBrowser(schemeHandler: schemeHandler, target: target)
        self.browser = browser
        let host = UIHostingController(rootView: DocsView(browser: browser) { [weak self] in self?.close() })
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        controller = host
        presenter.present(host, animated: true) { [weak host] in
            if host?.view.window == nil {
                WebHost.appendDocument(".probe-log.txt", "[docs] could not present from \(type(of: presenter)) (presenting: \(String(describing: presenter.presentedViewController)))\n")
            }
        }
    }

    func close() {
        controller?.dismiss(animated: true)
        controller = nil
    }
}
