import LineformCore
import SwiftUI
import UIKit

/// The Write / Read / Preview pill, built from the Mac's `EditorModeSegmentedControl`
/// (`Lineform/Editor/EditorChromeAndControls.swift`) with its values: 78 × 30 segments, 3 pt
/// padding, a 3 pt divider slot holding a 1 × 18 divider at 0.45 shown only between two unselected
/// segments, 14 pt regular labels, the light and dark colours, and the liquid bridge (a spring of 0.24 / 0.78 that stretches the selected pill
/// over both segments, then after 0.16 s a spring of 0.30 / 0.82 that settles it). Reduce Motion
/// skips the bridge and every animation (`EditorMotionPolicy`). The capsule is Liquid Glass
/// (iOS 26), in the theme's light or dark; the system makes it opaque under Reduce Transparency.
///
/// A phone has no hover, so the Mac's hover pill (0.48 of the selected fill) is the pressed state.
/// It floats at the top centre of the page (`DocumentScreen`); there is no bar behind it.
struct ModeSwitch: View {
    struct LiquidBridge: Equatable {
        var from: EditorDisplayMode
        var to: EditorDisplayMode
    }

    static let segmentWidth: CGFloat = 78
    static let segmentHeight: CGFloat = 30
    static let controlPadding: CGFloat = 3
    static let dividerSlotWidth: CGFloat = 3
    static let dividerSize = CGSize(width: 1, height: 18)
    static let dividerOpacity: Double = 0.45
    static let labelFontSize: CGFloat = 14
    static let selectedFillComponent: CGFloat = 0.86
    static let selectedFillAlpha: CGFloat = 0.74
    static let darkSelectedFillComponent: CGFloat = 0.20
    static let darkSelectedFillAlpha: CGFloat = 0.92
    static let textFillComponent: CGFloat = 0.18
    static let darkTextFillComponent: CGFloat = 0.92
    static let strokeWidth: CGFloat = 0.5
    /// The Mac's hover fill: this share of the selected fill, here while a segment is pressed.
    static let pressedFillShare: Double = 0.48
    static let bridgeAnimation = Animation.spring(response: 0.24, dampingFraction: 0.78)
    static let settleAnimation = Animation.spring(response: 0.30, dampingFraction: 0.82)
    static let liquidSettleDelay: TimeInterval = 0.16
    /// The control's top margin inside the safe area.
    static let topMargin: CGFloat = 8
    /// The height each segment takes touches in: the drawn capsule is 36 pt, so each segment's
    /// target reaches past it above and below (invisibly) to 44 pt.
    static let touchHeight: CGFloat = 44
    /// How far the touch band reaches past the drawn capsule, above and below.
    static var verticalTouchOutset: CGFloat { (touchHeight - intrinsicSize.height) / 2 }
    /// The padding above and below a segment's 30 pt label that makes its 44 pt target.
    static var segmentTouchPadding: CGFloat { (touchHeight - segmentHeight) / 2 }
    /// The room a page under the control keeps above its first line: the control and its margins.
    static var pageTopClearance: CGFloat { topMargin + intrinsicSize.height + topMargin }

    @Binding var mode: EditorDisplayMode
    var usesDarkChrome = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var liquidBridge: LiquidBridge?
    @State private var liquidTransitionID = 0

    private let modes = EditorDisplayMode.allCases

    init(mode: Binding<EditorDisplayMode>, usesDarkChrome: Bool = false) {
        _mode = mode
        self.usesDarkChrome = usesDarkChrome
    }

    var body: some View {
        ZStack(alignment: .leading) {
            selectedPill

            HStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, segment in
                    Button {
                        select(segment)
                    } label: {
                        Text(segment.title)
                            .font(.system(size: Self.labelFontSize, weight: .regular))
                            .foregroundStyle(Self.textFillColor(usesDarkChrome: usesDarkChrome))
                            .lineLimit(1)
                            .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SegmentPressStyle(
                        pressedFill: Self.selectedFillColor(usesDarkChrome: usesDarkChrome).opacity(Self.pressedFillShare),
                        isSelected: mode == segment
                    ))
                    .accessibilityLabel(segment.title)
                    .accessibilityAddTraits(mode == segment ? [.isSelected] : [])
                    // The label stays 14 pt (page chrome, the Mac's size); at the accessibility
                    // text sizes a long press shows it large.
                    .accessibilityShowsLargeContentViewer {
                        Text(segment.title)
                    }

                    if index < modes.index(before: modes.endIndex) {
                        Rectangle()
                            .fill(Self.dividerColor(usesDarkChrome: usesDarkChrome)
                                .opacity(Self.showsDivider(after: index, selection: mode) ? Self.dividerOpacity : 0))
                            .frame(width: Self.dividerSize.width, height: Self.dividerSize.height)
                            .padding(.horizontal, (Self.dividerSlotWidth - Self.dividerSize.width) / 2)
                    }
                }
            }
        }
        // The segments' touch padding already spans the height; the capsule is drawn at its own
        // 36 pt, centred in the 44 pt band.
        .padding(.horizontal, Self.controlPadding)
        .background {
            Color.clear
                .frame(height: Self.intrinsicSize.height)
                .glassEffect(.regular, in: Capsule())
        }
        .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Editor mode"))
    }

    private var selectedPill: some View {
        Capsule()
            .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome))
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(usesDarkChrome ? 0.16 : 0.36), lineWidth: Self.strokeWidth)
            }
            .frame(width: Self.pillWidth(bridge: liquidBridge), height: Self.segmentHeight)
            .offset(x: Self.pillOffset(bridge: liquidBridge, selection: mode))
            .animation(EditorMotionPolicy.animation(Self.settleAnimation, reduceMotion: reduceMotion), value: mode)
            .animation(EditorMotionPolicy.animation(Self.bridgeAnimation, reduceMotion: reduceMotion), value: liquidBridge)
    }

    private func select(_ segment: EditorDisplayMode) {
        guard segment != mode else { return }
        liquidTransitionID += 1
        guard let bridge = Self.bridge(from: mode, to: segment, reduceMotion: reduceMotion) else {
            liquidBridge = nil
            mode = segment
            return
        }
        let transitionID = liquidTransitionID
        withAnimation(Self.bridgeAnimation) {
            liquidBridge = bridge
            mode = segment
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liquidSettleDelay) {
            guard transitionID == liquidTransitionID else { return }
            withAnimation(Self.settleAnimation) {
                liquidBridge = nil
            }
        }
    }

    // MARK: - Geometry and colours (static, so tests read the Mac's values)

    /// The bridge a switch starts with, or nil under Reduce Motion (the Mac's
    /// `usesReduceMotionForLiquidBridge`).
    static func bridge(from source: EditorDisplayMode, to destination: EditorDisplayMode, reduceMotion: Bool) -> LiquidBridge? {
        guard EditorMotionPolicy.usesAnimatedTransitions(reduceMotion: reduceMotion), source != destination else { return nil }
        return LiquidBridge(from: source, to: destination)
    }

    static func segmentOffset(for mode: EditorDisplayMode) -> CGFloat {
        guard let index = EditorDisplayMode.allCases.firstIndex(of: mode) else { return 0 }
        return CGFloat(index) * (segmentWidth + dividerSlotWidth)
    }

    static func pillOffset(bridge: LiquidBridge?, selection: EditorDisplayMode) -> CGFloat {
        guard let bridge else { return segmentOffset(for: selection) }
        return min(segmentOffset(for: bridge.from), segmentOffset(for: bridge.to))
    }

    static func pillWidth(bridge: LiquidBridge?) -> CGFloat {
        guard let bridge else { return segmentWidth }
        return abs(segmentOffset(for: bridge.to) - segmentOffset(for: bridge.from)) + segmentWidth
    }

    /// The whole control's drawn size: three segments, two divider slots, the padding all round.
    /// Its layout is `touchHeight` tall (`touchSize`).
    static var intrinsicSize: CGSize {
        let count = CGFloat(EditorDisplayMode.allCases.count)
        return CGSize(
            width: count * segmentWidth + (count - 1) * dividerSlotWidth + 2 * controlPadding,
            height: segmentHeight + 2 * controlPadding
        )
    }

    /// The control's layout size: the drawn width, the touch band's height.
    static var touchSize: CGSize {
        CGSize(width: intrinsicSize.width, height: touchHeight)
    }

    /// A divider shows only between two unselected segments.
    static func showsDivider(after index: Int, selection: EditorDisplayMode) -> Bool {
        let modes = EditorDisplayMode.allCases
        guard index >= 0, index < modes.count - 1 else { return false }
        return modes[index] != selection && modes[index + 1] != selection
    }

    static func selectedFillColor(usesDarkChrome: Bool) -> Color {
        usesDarkChrome
            ? Color(white: darkSelectedFillComponent, opacity: darkSelectedFillAlpha)
            : Color(white: selectedFillComponent, opacity: selectedFillAlpha)
    }

    static func textFillColor(usesDarkChrome: Bool) -> Color {
        Color(white: usesDarkChrome ? darkTextFillComponent : textFillComponent)
    }

    /// White on dark chrome; the light separator colour otherwise (the Mac's `separatorColor`),
    /// resolved for the theme rather than the system appearance.
    static func dividerColor(usesDarkChrome: Bool) -> Color {
        usesDarkChrome
            ? .white
            : Color(uiColor: UIColor.separator.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }
}

extension ModeSwitch {
    /// The press animation: the Mac's hover, `easeInOut` over `LineformDesign.Motion.hover`
    /// (0.12 s); none under Reduce Motion.
    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        EditorMotionPolicy.animation(.easeInOut(duration: LineformDesign.Motion.hover), reduceMotion: reduceMotion)
    }

    /// The pressed pill's opacity: shown behind an unselected segment while it is held.
    static func pressedPillOpacity(isPressed: Bool, isSelected: Bool) -> Double {
        isPressed && !isSelected ? 1 : 0
    }
}

/// A segment's pressed state: the Mac's hover pill behind an unselected segment while it is held.
/// The pill is always drawn; only its opacity changes, so the press fades in and out as the Mac's
/// hover does.
private struct SegmentPressStyle: ButtonStyle {
    var pressedFill: Color
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentPressBody(label: configuration.label, isPressed: configuration.isPressed,
                         pressedFill: pressedFill, isSelected: isSelected)
    }
}

private struct SegmentPressBody<Label: View>: View {
    var label: Label
    var isPressed: Bool
    var pressedFill: Color
    var isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .background {
                Capsule()
                    .fill(pressedFill)
                    .opacity(ModeSwitch.pressedPillOpacity(isPressed: isPressed, isSelected: isSelected))
            }
            // The 44 pt target: invisible room above and below the 30 pt segment.
            .padding(.vertical, ModeSwitch.segmentTouchPadding)
            .contentShape(Rectangle())
            .animation(ModeSwitch.pressAnimation(reduceMotion: reduceMotion), value: isPressed)
    }
}

extension UIScrollView {
    /// Keeps the page's last line clear of the floating buttons at the bottom (the Menu button
    /// and Preview's link button): the extra bottom inset is applied as content inset.
    func setBottomChromeInset(_ inset: CGFloat) {
        guard abs(contentInset.bottom - inset) > 0.5 else { return }
        contentInset.bottom = inset
    }

    /// Keeps the page's first line clear of the floating mode control: the extra top inset is
    /// applied as content inset, and a page showing its top stays at the (new) top.
    func setTopChromeInset(_ inset: CGFloat) {
        guard abs(contentInset.top - inset) > 0.5 else { return }
        let wasAtTop = contentOffset.y <= -adjustedContentInset.top + 1
        contentInset.top = inset
        if wasAtTop {
            contentOffset = CGPoint(x: contentOffset.x, y: -adjustedContentInset.top)
        }
    }
}

// MARK: - The document's name on the page

/// The open document's file name, in small secondary text at the top of the page, above the first
/// line (owner review 4: a renamable name on the page itself, not up in the menu). It scrolls with
/// the text. A tap opens Rename; Untitled (no file yet) shows the name and offers nothing.
/// Write and Read both keep `DocumentNameTag.topSpace` above the first line, so the text does not
/// move between the modes.
final class DocumentNameTag: UIButton {
    /// The name's line (20 pt at the default text size, the footnote line plus 4 pt at larger
    /// text sizes) and the gap below it to the first line of text.
    static var height: CGFloat {
        max(20, (UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 4).rounded(.up))
    }
    static let gap: CGFloat = 10
    static var topSpace: CGFloat { height + gap }

    var onRename: (() -> Void)?
    /// The last name shown, so a text-size change can redraw it in the new size.
    private var shown: (name: String, ink: UIColor, canRename: Bool)?

    /// How far below the text's baseline the dashes run.
    static let dashOffset: CGFloat = 3

    private lazy var dashLayer: CAShapeLayer = {
        let dashes = CAShapeLayer()
        dashes.lineWidth = 1
        dashes.lineDashPattern = [3, 2]
        dashes.fillColor = nil
        layer.addSublayer(dashes)
        return dashes
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let label = titleLabel, let font = label.font else { return }
        let text = label.frame
        let baseline = text.minY + font.ascender
        let y = (baseline + Self.dashOffset).rounded() + 0.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: text.minX, y: y))
        path.addLine(to: CGPoint(x: text.maxX, y: y))
        dashLayer.frame = bounds
        dashLayer.path = path.cgPath
    }

    static func make() -> DocumentNameTag {
        let tag = DocumentNameTag(type: .system)
        tag.contentHorizontalAlignment = .leading
        tag.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        tag.titleLabel?.adjustsFontForContentSizeCategory = true
        tag.titleLabel?.lineBreakMode = .byTruncatingMiddle
        tag.accessibilityIdentifier = "document.name"
        // A tap opens Rename at once (owner review 4: a menu first was one tap too many).
        tag.addAction(UIAction { [weak tag] _ in tag?.onRename?() }, for: .primaryActionTriggered)
        // The name follows the text size setting live (the accessibility audit: a fixed size read
        // as "Dynamic Type partially unsupported").
        tag.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (tag: DocumentNameTag, _: UITraitCollection) in
            guard let shown = tag.shown else { return }
            tag.shown = nil
            tag.update(name: shown.name, ink: shown.ink, canRename: shown.canRename)
            tag.superview?.setNeedsLayout()
        }
        return tag
    }

    /// Shows `name` in `ink`; `canRename` gives it the Rename… menu.
    func update(name: String, ink: UIColor, canRename: Bool) {
        // A renamable name carries a quiet dashed underline in its own grey, so it reads as
        // something to tap (not the AI's blue dotted words).
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: ink,
        ]
        let title = NSAttributedString(string: name, attributes: attributes)
        if attributedTitle(for: .normal) != title { setAttributedTitle(title, for: .normal) }
        shown = (name, ink, canRename)
        // The dashes are drawn, not a text underline, so they sit a little below the letters
        // (owner review 5: the text underline sat too tight).
        dashLayer.strokeColor = ink.withAlphaComponent(0.6).cgColor
        dashLayer.isHidden = !canRename
        setNeedsLayout()
        isUserInteractionEnabled = canRename
        accessibilityLabel = name
        accessibilityHint = canRename ? String(localized: "Rename…") : nil
        accessibilityTraits = canRename ? .button : .staticText
    }
}

extension UITextView {
    /// Lays `tag` out across the text column, `top` below the content's top.
    func layoutDocumentNameTag(_ tag: DocumentNameTag?, top: CGFloat) {
        guard let tag, tag.superview === self else { return }
        let padding = textContainer.lineFragmentPadding
        let x = textContainerInset.left + padding
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right - 2 * padding)
        let frame = CGRect(x: x, y: top, width: width, height: DocumentNameTag.height)
        if tag.frame != frame { tag.frame = frame }
    }
}
