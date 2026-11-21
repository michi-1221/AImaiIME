import AIMECore
import AppKit

/// 変換の見通しを出す小さな窓。フォーカスを取らず、クリックも受けない。
/// 中身は「→ 変換結果」と、小さく変換キーの名前（例: 右⌘で変換）。置き場所の決め方は AIMECore の `PreviewPlacement`。
final class PreviewPanel {
    static let shared = PreviewPanel()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private static let maxWidth: CGFloat = 420
    /// 今、窓を出しているコントローラー（そのコントローラーが消えたら窓も消すため）
    private var owner: ObjectIdentifier?
    /// 結果の文字列の幅（左右の余白をそろえるため、文字列を測って決める）
    private var resultWidth: NSLayoutConstraint!

    private init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true

        resultLabel.font = .systemFont(ofSize: 15)
        resultLabel.lineBreakMode = .byCharWrapping
        resultLabel.maximumNumberOfLines = 4
        resultLabel.preferredMaxLayoutWidth = Self.maxWidth
        resultLabel.isSelectable = false
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.addArrangedSubview(resultLabel)
        stack.addArrangedSubview(hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        resultWidth = resultLabel.widthAnchor.constraint(equalToConstant: 100)
        resultWidth.isActive = true
        panel.contentView = effect
    }

    /// 文字列を折り返し込みで測った幅（ラベルの内側の余白 2pt ずつを含む）。
    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        let rect = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.width) + 10
    }

    /// 窓を出す（main スレッドで呼ぶ）。`lineRect` はカーソルのある行の矩形（画面座標）。
    func show(owner: AnyObject, text: String, hint: String, lineRect: NSRect) {
        self.owner = ObjectIdentifier(owner)
        resultLabel.stringValue = "→ " + text
        hintLabel.stringValue = hint
        // 結果の幅を実際の文字列の幅にする（詰めて測ると右の余白だけ狭く見えるため）。ヒントのほうが長ければそちらに合わせる
        let width = max(Self.measuredWidth(resultLabel.stringValue, font: resultLabel.font ?? .systemFont(ofSize: 15)),
                        Self.measuredWidth(hint, font: hintLabel.font ?? .systemFont(ofSize: 10)))
        resultWidth.constant = min(width, Self.maxWidth + 4)
        resultLabel.preferredMaxLayoutWidth = resultWidth.constant
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(lineRect.origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(PreviewPlacement.frame(size: size, lineRect: lineRect, screen: visible), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        owner = nil
        panel.orderOut(nil)
    }

    /// 窓の持ち主が `id` のときだけ消す（コントローラーの解放時）。main スレッドで呼ぶ。
    func hide(ifOwnedBy id: ObjectIdentifier) {
        guard owner == id else { return }
        hide()
    }
}
