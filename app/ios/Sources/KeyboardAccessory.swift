import GameController
import UIKit
import WebKit

/// Pythonista-style extra keys that are part of the keyboard: a UIInputView
/// with the keyboard's own material, installed as the inputAccessoryView of
/// WKWebView's content view. It also replaces the default prev/next/done bar.
///
/// The web app tells us which kind of field has focus (`keyboard.mode`):
/// "code" (editor) and "console" (>>>, input()) show the keys; "plain" (file
/// search, UI apps) shows nothing. Plain keyboard traits (no capitalization,
/// autocorrection or smart punctuation) come from the editor's HTML
/// attributes (`autocapitalize`, `autocorrect`, `spellcheck`), which WebKit
/// maps to all of them.
///
/// No private selectors (D56): the content view is found as the scroll
/// view's `UITextInput` subview, and only `inputAccessoryView`, a public
/// UIResponder property, is overridden.
@MainActor
final class KeyboardAccessory: NSObject, UIInputViewAudioFeedback {
    /// code: the editor (keys + code actions), console: >>> and input() (keys), plain: anything else.
    enum Mode: String { case code, console, plain }

    struct Key {
        let label: String
        let action: String  // "insert:<text>:<cursor>" or a command name
        var alternate: String? = nil  // long-press action
        var symbol: String? = nil  // SF Symbol instead of a label
    }

    /// Only indent and undo do more when held (dedent, redo): those have no keys of their own.
    static let keys: [Key] = [
        Key(label: "⇥", action: "indent", alternate: "dedent", symbol: "arrow.right.to.line"),
        Key(label: "undo", action: "undo", alternate: "redo", symbol: "arrow.uturn.backward"),
        Key(label: "(", action: "insert:():1"),
        Key(label: ")", action: "insert:)"),
        Key(label: "[", action: "insert:[]:1"),
        Key(label: "]", action: "insert:]"),
        Key(label: "{", action: "insert:{}:1"),
        Key(label: "}", action: "insert:}"),
        Key(label: ":", action: "insert::"),
        Key(label: "=", action: "insert:="),
        Key(label: "\"", action: "insert:\"\":1"),
        Key(label: "'", action: "insert:'':1"),
        Key(label: "_", action: "insert:_"),
        Key(label: ".", action: "insert:."),
        Key(label: ",", action: "insert:, "),
        Key(label: "#", action: "insert:# "),
        Key(label: "+", action: "insert:+"),
        Key(label: "-", action: "insert:-"),
        Key(label: "*", action: "insert:*"),
        Key(label: "/", action: "insert:/"),
        Key(label: "<", action: "insert:<"),
        Key(label: ">", action: "insert:>"),
        Key(label: "!", action: "insert:!"),
        Key(label: "%", action: "insert:%"),
        Key(label: "←", action: "left", symbol: "arrow.left"),
        Key(label: "→", action: "right", symbol: "arrow.right"),
    ]

    static let shared = KeyboardAccessory()
    weak var webView: WKWebView?
    private(set) var mode: Mode = .plain
    private lazy var codeBar: UIInputView = makeBar()
    /// The same keys for native code fields (the console's >>> and input()).
    /// A separate view: the editor's keyboard may still be on its way out.
    private(set) lazy var fieldBar: UIInputView = makeBar()
    /// The native field the field bar types into (the first responder).
    weak var field: UITextField?

    var enableInputClicksWhenVisible: Bool { true }

    /// What WKContentView's inputAccessoryView returns.
    var currentView: UIView? {
        guard mode != .plain else { return nil }
        (codeBar as? AccessoryBar)?.prepare()
        return codeBar
    }

    /// What the native code fields' inputAccessoryView returns.
    var fieldView: UIView {
        (fieldBar as? AccessoryBar)?.prepare()
        return fieldBar
    }

    /// Whether the last keyboard seen was the software keyboard; before any,
    /// whether there is no hardware keyboard. A bar starts out the way the
    /// keyboard will most likely be, so it doesn't appear and then collapse
    /// (or the other way around) while the keyboard comes up.
    fileprivate static var softwareKeyboard: Bool?
    fileprivate static var expectSoftwareKeyboard: Bool { softwareKeyboard ?? (GCKeyboard.coalesced == nil) }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        contentView?.reloadInputViews()
    }

    // MARK: installing

    /// WebKit's content view: the view that takes the keyboard (UITextInput).
    private var contentView: UIView? {
        webView?.scrollView.subviews.first { $0 is UITextInput }
    }

    /// Swap WKContentView's class for a subclass whose inputAccessoryView is ours.
    func install(on webView: WKWebView) {
        self.webView = webView
        guard let content = contentView else { return }
        let base: AnyClass = object_getClass(content)!
        // install runs again after each navigation: the view may already be ours
        // (subclassing it again would chain every override twice).
        if NSStringFromClass(base).hasSuffix("_TerrariumAccessory") { return }
        let name = "\(NSStringFromClass(base))_TerrariumAccessory"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let created = objc_allocateClassPair(base, name, 0) {
            let block: @convention(block) (AnyObject) -> UIView? = { _ in
                MainActor.assumeIsolated { KeyboardAccessory.shared.currentView }
            }
            let selector = #selector(getter: UIResponder.inputAccessoryView)
            class_addMethod(created, selector, imp_implementationWithBlock(block), "@@:")
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass { object_setClass(content, subclass) }
    }

    /// Before the page focuses a field without a tap (a native command, a
    /// problem in the list, a new cell): WebKit only brings up the keyboard on
    /// its own for focus from a user gesture in the page, or when its content
    /// view is already first responder (`keyboard.take`).
    func takeKeyboard() {
        guard let content = contentView, !content.isFirstResponder else { return }
        content.becomeFirstResponder()
    }

    // MARK: the bar

    /// Launch hook (`focus`): what a tap on the editor does, so screenshots
    /// can show the keyboard.
    @discardableResult
    func focusForTesting() -> Bool {
        guard let content = contentView else { return false }
        if content.isFirstResponder { return true }
        let ok = content.becomeFirstResponder()
        WebHost.appendDocument(".probe-log.txt", "[keyboard] focus hook: \(ok ? "first responder" : "could not become first responder")\n")
        return ok
    }

    private func makeBar() -> UIInputView {
        // A transparent input view holding two glass platters (iOS 26 style):
        // the scrolling keys and the dismiss button. Above the software keyboard
        // they float over the app like the system's bars; alone at the bottom of
        // the screen (hardware keyboard, undocked keyboard) the bar grows by the
        // bottom safe area so nothing sits under the home indicator or corners.
        let bar = AccessoryBar(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight), inputViewStyle: .default)
        bar.allowsSelfSizing = true
        bar.backgroundColor = .clear

        let keys = Self.glass()
        let dismiss = Self.glass()
        bar.addSubview(keys)
        bar.addSubview(dismiss)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        keys.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, key) in Self.keys.enumerated() {
            stack.addArrangedSubview(makeKey(key, tag: index))
        }
        scroll.addSubview(stack)

        let hide = makeKey(Key(label: "Hide Keyboard", action: "dismiss", symbol: "keyboard.chevron.compact.down"), tag: -1)
        hide.translatesAutoresizingMaskIntoConstraints = false
        dismiss.contentView.addSubview(hide)

        let platter = Self.barHeight - 2 * Self.margin
        let inner: CGFloat = 4
        NSLayoutConstraint.activate([
            keys.heightAnchor.constraint(equalToConstant: platter),
            keys.topAnchor.constraint(equalTo: bar.topAnchor, constant: Self.margin),
            keys.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: Self.margin),
            keys.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -Self.margin),
            dismiss.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -Self.margin),
            dismiss.topAnchor.constraint(equalTo: keys.topAnchor),
            dismiss.heightAnchor.constraint(equalToConstant: platter),
            dismiss.widthAnchor.constraint(equalToConstant: platter),

            scroll.leadingAnchor.constraint(equalTo: keys.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: keys.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: keys.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: keys.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: inner + 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -inner - 4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inner),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inner),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -2 * inner),

            hide.topAnchor.constraint(equalTo: dismiss.contentView.topAnchor, constant: inner),
            hide.bottomAnchor.constraint(equalTo: dismiss.contentView.bottomAnchor, constant: -inner),
            hide.leadingAnchor.constraint(equalTo: dismiss.contentView.leadingAnchor, constant: inner),
            hide.trailingAnchor.constraint(equalTo: dismiss.contentView.trailingAnchor, constant: -inner),
        ])
        return bar
    }

    fileprivate static let barHeight: CGFloat = 60
    private static let margin: CGFloat = 6

    private static func glass() -> UIVisualEffectView {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private static let pressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.1) }

    private func makeKey(_ key: Key, tag: Int) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        if let symbol = key.symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        } else {
            var title = AttributedString(key.label)
            title.font = UIFont.monospacedSystemFont(ofSize: 19, weight: .regular)
            config.attributedTitle = title
        }
        let button = KeyButton(configuration: config)
        button.tag = tag
        // Our own pressed state (the plain style would only dim the glyph).
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.background.backgroundColor = button.isHighlighted ? Self.pressed : .clear
            button.configuration = config
        }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        button.accessibilityLabel = key.label
        button.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(keyUp(_:)), for: .touchUpInside)
        // Scrolling the bar cancels the touch: no key.
        button.addTarget(self, action: #selector(keyCancel(_:)), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        // Touch and hold does more: a small dot next to the symbol says so.
        button.hasAlternate = key.alternate != nil
        return button
    }

    // MARK: actions

    /// Touch and hold: timed from the key's own touch events. A gesture
    /// recognizer on the key never won against the interactive glass and the
    /// scroll view around it.
    static let holdDuration: TimeInterval = 0.35
    private var holdTimer: Timer?
    /// The key whose alternate fired: its release does nothing.
    private var held: UIButton?

    @objc private func keyDown(_ sender: UIButton) {
        UIDevice.current.playInputClick()
        holdTimer?.invalidate()
        held = nil
        guard Self.keys.indices.contains(sender.tag), let alternate = Self.keys[sender.tag].alternate else { return }
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self, weak sender] _ in
            MainActor.assumeIsolated {
                guard let self, let sender else { return }
                self.held = sender
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.send(alternate, from: sender)
            }
        }
        // Common modes: while a finger is down in the bar's scroll view the run
        // loop is in tracking mode, where a default-mode timer doesn't fire.
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    @objc private func keyCancel(_ sender: UIButton) {
        holdTimer?.invalidate()
        held = nil
    }

    @objc private func keyUp(_ sender: UIButton) {
        holdTimer?.invalidate()
        if held === sender {
            held = nil
            return
        }
        if sender.tag == -1 {
            send("dismiss", from: sender)
        } else if Self.keys.indices.contains(sender.tag) {
            send(Self.keys[sender.tag].action, from: sender)
        }
    }

    private func send(_ action: String, from key: UIView) {
        if key.isDescendant(of: fieldBar) {
            if let field { apply(action, to: field) }
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [action]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__terrariumKey?.(\(json)[0])")
    }
}

extension KeyboardAccessory {
    /// The editor's commands on a one-line UITextField. Edits go through
    /// UITextInput, so they are undoable and the field reports the change.
    fileprivate func apply(_ action: String, to field: UITextField) {
        let start = field.beginningOfDocument
        func caret(_ position: UITextPosition) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
        switch action {
        case "dismiss":
            _ = field.resignFirstResponder()
            return
        case "undo":
            field.undoManager?.undo()
        case "redo":
            field.undoManager?.redo()
        case "left", "right":
            guard let range = field.selectedTextRange else { return }
            let left = action == "left"
            if !range.isEmpty { caret(left ? range.start : range.end); return }
            if let p = field.position(from: range.start, offset: left ? -1 : 1) { caret(p) }
            return
        case "indent":
            field.insertText("    ")
        case "dedent", "comment":
            let text = field.text ?? ""
            let remove: Int, insert: String
            if action == "dedent" {
                remove = text.prefix(4).prefix { $0 == " " }.count
                insert = ""
            } else if text.hasPrefix("# ") || text.hasPrefix("#") {
                remove = text.hasPrefix("# ") ? 2 : 1
                insert = ""
            } else {
                remove = 0
                insert = "# "
            }
            guard remove > 0 || !insert.isEmpty, let end = field.position(from: start, offset: remove),
                  let range = field.textRange(from: start, to: end) else { return }
            field.replace(range, withText: insert)
        default:
            guard action.hasPrefix("insert:") else { return }
            var body = String(action.dropFirst("insert:".count))
            var back = 0
            // "insert:<text>:<cursor>": the caret goes <cursor> characters into the text.
            if let colon = body.lastIndex(of: ":"), colon != body.startIndex,
               let cursor = Int(body[body.index(after: colon)...]) {
                body = String(body[..<colon])
                back = body.count - cursor
            }
            field.insertText(body)
            if back > 0, let range = field.selectedTextRange, let p = field.position(from: range.start, offset: -back) { caret(p) }
        }
        field.sendActions(for: .editingChanged)
    }
}

/// A key of the bar; one that does more when held has a dot next to its symbol.
private final class KeyButton: UIButton {
    private let dot = UIView()

    var hasAlternate = false {
        didSet {
            if hasAlternate && dot.superview == nil {
                dot.isUserInteractionEnabled = false
                dot.backgroundColor = .tertiaryLabel
                dot.layer.cornerRadius = 1.5
                addSubview(dot)
            }
            dot.isHidden = !hasAlternate
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard hasAlternate else { return }
        // Just above and right of the symbol, like a superscript, not in the key's corner.
        let glyph = (configuration?.image != nil ? imageView?.frame : titleLabel?.frame) ?? bounds
        dot.frame = CGRect(x: min(bounds.maxX - 4, glyph.maxX + 1), y: max(1, glyph.minY - 1), width: 3, height: 3)
    }
}

/// The bar only shows with the software keyboard. With a hardware keyboard,
/// or when the software keyboard was hidden while the field kept focus
/// (iPad's hide key, the minimized keyboard), UIKit would leave it alone at
/// the bottom of the screen; there it collapses to nothing, and comes back
/// with the keyboard.
private final class AccessoryBar: UIInputView {
    private var height = KeyboardAccessory.barHeight
    /// The software keyboard (without the bar) is taller than this, even an
    /// iPhone's in landscape; the minimized keyboard's strip is not.
    private static let softwareKeyboardHeight: CGFloat = 120

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        // "Will": decide before the keyboard animates, so the bar never flashes.
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillShowNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    @objc private func keyboardFrame(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screen = (note.object as? UIScreen) ?? window?.screen
        let bottom = screen?.bounds.maxY ?? end.maxY
        // A keyboard going away slides below the screen: that says nothing
        // about the next one. With no software keyboard the frame is empty.
        if !end.isEmpty && end.minY >= bottom { return }
        let visible = end.isEmpty ? 0 : max(0, bottom - end.minY)
        // The frame includes the bar as it is now.
        let software = visible - height > Self.softwareKeyboardHeight
        KeyboardAccessory.softwareKeyboard = software
        setHeight(software ? KeyboardAccessory.barHeight : 0)
    }

    /// Before the bar is handed to UIKit: start out as the keyboard will be.
    func prepare() {
        guard window == nil else { return }
        setHeight(KeyboardAccessory.expectSoftwareKeyboard ? KeyboardAccessory.barHeight : 0)
    }

    private func setHeight(_ next: CGFloat) {
        for view in subviews { view.isHidden = next == 0 }
        if window == nil { frame.size.height = next }  // what the keyboard host measures
        if next != height {
            height = next
            invalidateIntrinsicContentSize()
        }
        applyHeight()
    }

    /// The keyboard host measures the bar when it installs it, into a height
    /// constraint of its own, and not again while the bar stays installed (it
    /// may also add that constraint after our last change). Without this a
    /// collapsed bar would still push the app's content up.
    private func applyHeight() {
        for constraint in constraints where constraint.identifier == "_UIKBAutolayoutHeightConstraint" && constraint.constant != height {
            constraint.constant = height
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyHeight()
    }

    override func updateConstraints() {
        applyHeight()
        super.updateConstraints()
    }

    override func layoutSubviews() {
        applyHeight()
        super.layoutSubviews()
    }
}
