import LineformCore
import UIKit

/// A pill over the Read view: the Copy pill at the top right of every code block, or the
/// Reconnect pill after every image that did not load. The Mac draws these as geometry and
/// hit-tests them in `mouseDown`; on iPhone they are real buttons, laid over the text from
/// `NSLayoutManager.boundingRect` (`LineformReadView.layoutOverlays`), so they take touches before
/// the text view does and VoiceOver reaches them. They are subviews of the text view in content
/// coordinates, so a scroll carries them with the text.
///
/// The values are the Mac's (`MarkdownPreviewTextView`): a 26 pt circle with a 13 pt
/// `doc.on.doc` glyph (a `checkmark` for 1.0 s after a copy), and a 22 pt high pill with radius 11
/// holding the 11 pt medium "Reconnect" label, a 5 pt gap and an 11 pt `arrow.counterclockwise`
/// glyph. The fill is the Mac's quiet one: black at 0.05 on light pages, white at 0.13 on dark,
/// with a 1 pt stroke at 0.10 / 0.22. The phone has no hover, so the Mac's hover fill
/// (0.11 / 0.22) is the pressed state.
///
/// Accessibility: each pill takes touches in at least a 44 pt square around it (`minimumTouchSide`)
/// without being drawn larger, and, being fixed-size chrome, shows the Large Content Viewer on a
/// long press at the accessibility text sizes. VoiceOver reaches the pills as the Read view's
/// custom actions (the text view is one element), and a copy is announced.
final class ReadOverlayButton: UIButton {
    enum Kind: Equatable {
        case copy
        case reconnect
    }

    static let copyPillSize = CGSize(width: 26, height: 26)
    static let pillInset: CGFloat = 8
    static let pillCornerRadius: CGFloat = 11
    static let reconnectPillHeight: CGFloat = 22
    static let reconnectPillVerticalNudge: CGFloat = 6
    static let reconnectPillGap: CGFloat = 5
    /// The Reconnect pill's distance after the placeholder run.
    static let reconnectPillLeadingGap: CGFloat = 8
    static let pillLabelFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    static let copyGlyphSize = CGSize(width: 13, height: 13)
    static let reconnectGlyphSize = CGSize(width: 11, height: 11)
    /// The smallest touch target, on each side: Apple's 44 pt.
    static let minimumTouchSide: CGFloat = 44

    /// The pill's drawn label. One constant, because its WIDTH is measured from it, as on the Mac.
    static let reconnectPillLabel = String(localized: "Reconnect")

    /// Measured from the label in the interface's language at the pill's font, so a long
    /// translation (German "Erneut verbinden") gets a wider pill rather than a cut label.
    static let reconnectPillWidth: CGFloat = reconnectPillWidth(for: reconnectPillLabel)

    static func reconnectPillWidth(for label: String) -> CGFloat {
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: pillLabelFont]).width)
        return ceil(labelWidth + reconnectPillGap + reconnectGlyphSize.width + 24)
    }

    let kind: Kind
    /// For Copy, the code body's range in the source; for Reconnect, the whole image line's.
    var sourceRange: NSRange
    /// Copy pills only: the block's number in reading order, for the VoiceOver label.
    var codeBlockNumber = 0 {
        didSet { updateAccessibility() }
    }
    /// Copy pills only: showing the checkmark after a copy.
    var isShowingCopied = false {
        didSet {
            guard isShowingCopied != oldValue else { return }
            updateGlyph()
            updateAccessibility()
        }
    }

    private let glyphView = UIImageView()
    private let label = UILabel()
    private var usesDarkChrome = false
    private var ink: UIColor = .label

    init(kind: Kind, sourceRange: NSRange) {
        self.kind = kind
        self.sourceRange = sourceRange
        super.init(frame: .zero)
        layer.borderWidth = 1
        layer.cornerRadius = kind == .copy ? Self.copyPillSize.height / 2 : Self.pillCornerRadius
        layer.cornerCurve = .continuous
        glyphView.contentMode = .scaleAspectFit
        glyphView.isUserInteractionEnabled = false
        addSubview(glyphView)
        if kind == .reconnect {
            label.text = Self.reconnectPillLabel
            label.font = Self.pillLabelFont
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        showsLargeContentViewer = true
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        updateGlyph()
        updateAccessibility()
    }

    /// The pill's bounds grown to at least `minimumTouchSide` on each side, about its centre.
    var touchBounds: CGRect {
        let dx = max(0, Self.minimumTouchSide - bounds.width) / 2
        let dy = max(0, Self.minimumTouchSide - bounds.height) / 2
        return bounds.insetBy(dx: -dx, dy: -dy)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touchBounds.contains(point)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReadOverlayButton is made in code")
    }

    /// The theme's page decides the fill and the ink.
    func apply(theme: Theme) {
        usesDarkChrome = theme.usesDarkChrome
        ink = theme.readableInk(theme.textColor.withAlphaComponent(0.85))
        label.textColor = ink
        glyphView.tintColor = ink
        updateFill()
    }

    override var isHighlighted: Bool {
        didSet { updateFill() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch kind {
        case .copy:
            glyphView.frame = CGRect(
                x: bounds.midX - Self.copyGlyphSize.width / 2,
                y: bounds.midY - Self.copyGlyphSize.height / 2,
                width: Self.copyGlyphSize.width,
                height: Self.copyGlyphSize.height
            )
        case .reconnect:
            let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height))
            let contentWidth = labelSize.width + Self.reconnectPillGap + Self.reconnectGlyphSize.width
            let startX = bounds.midX - contentWidth / 2
            label.frame = CGRect(x: startX, y: bounds.midY - labelSize.height / 2, width: labelSize.width, height: labelSize.height)
            glyphView.frame = CGRect(
                x: startX + labelSize.width + Self.reconnectPillGap,
                y: bounds.midY - Self.reconnectGlyphSize.height / 2,
                width: Self.reconnectGlyphSize.width,
                height: Self.reconnectGlyphSize.height
            )
        }
    }

    private func updateFill() {
        let tint: UIColor = usesDarkChrome ? .white : .black
        let restAlpha: CGFloat = usesDarkChrome ? 0.13 : 0.05
        let pressedAlpha: CGFloat = usesDarkChrome ? 0.22 : 0.11
        backgroundColor = tint.withAlphaComponent(isHighlighted ? pressedAlpha : restAlpha)
        layer.borderColor = tint.withAlphaComponent(usesDarkChrome ? 0.22 : 0.10).cgColor
    }

    private func updateGlyph() {
        let name: String
        switch kind {
        case .copy: name = isShowingCopied ? "checkmark" : "doc.on.doc"
        case .reconnect: name = "arrow.counterclockwise"
        }
        let pointSize = kind == .copy ? Self.copyGlyphSize.height : Self.reconnectGlyphSize.height
        glyphView.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize))
        largeContentImage = UIImage(systemName: name)
    }

    private func updateAccessibility() {
        switch kind {
        case .copy:
            accessibilityLabel = String(localized: "Copy code block \(codeBlockNumber)")
            accessibilityValue = isShowingCopied ? String(localized: "Copied") : nil
            largeContentTitle = isShowingCopied ? String(localized: "Copied") : accessibilityLabel
        case .reconnect:
            accessibilityLabel = String(localized: "Reconnect image")
            accessibilityValue = nil
            largeContentTitle = Self.reconnectPillLabel
        }
    }
}
