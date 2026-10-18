import UIKit
import WebKit

/// The app's web view. Adds code actions to the text selection menu (the
/// callout with Cut/Copy/Paste) while the code editor has focus.
/// WKWebView's buildMenu(with:) is consulted for that menu (WKWebViewIOS.mm).
final class CodeWebView: WKWebView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, KeyboardAccessory.shared.mode == .code else { return }
        let jump = UIAction(title: "Jump to Definition", image: UIImage(systemName: "arrow.forward.to.line")) { [weak self] _ in
            self?.evaluateJavaScript("window.__terrariumKey?.('definition')")
        }
        let info = UIAction(title: "Show Info", image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.evaluateJavaScript("window.__terrariumKey?.('info')")
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [jump, info]), atStartOfMenu: .root)
    }
}
