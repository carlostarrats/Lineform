import SwiftUI

struct EditorAuxiliaryPresentation: Equatable {
    enum Kind: Equatable {
        case nativeInspector
        case trailingDrawer
        case centeredModal
    }

    var kind: Kind
    var presenter: EditorAuxiliaryPresenter
    var accessibilityLabel: String
    var minimumWidth: CGFloat?
    var idealWidth: CGFloat?
    var maximumWidth: CGFloat?
    var transitionStyle: EditorAuxiliaryTransitionStyle
    var animationDuration: Double?

    static let readingExperience = EditorAuxiliaryPresentation(
        kind: .nativeInspector,
        presenter: .systemInspector,
        accessibilityLabel: "Reading Experience Inspector",
        minimumWidth: 280,
        idealWidth: 320,
        maximumWidth: 380,
        transitionStyle: .systemInspector,
        animationDuration: nil
    )

    static let markdownBasics = EditorAuxiliaryPresentation(
        kind: .centeredModal,
        presenter: .customOverlay,
        // Announced by VoiceOver as the modal's name; must match the visible "Info" title, which
        // now spans Markdown Basics + Diagrams + Math (not just the original Markdown Basics).
        accessibilityLabel: "Info",
        minimumWidth: nil,
        idealWidth: nil,
        maximumWidth: nil,
        transitionStyle: .fadeAndMoveUp,
        animationDuration: 0.24
    )
}

enum EditorAuxiliaryPresenter: Equatable {
    case systemInspector
    case customLayout
    case customOverlay
}

enum EditorAuxiliaryTransitionStyle: Equatable {
    case instant
    case systemInspector
    case fadeAndMoveUp
    case slideAndFade
}

private struct MarkdownGuideHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared visual language for Lineform's in-window "Muse-style" modals — the Info
/// modal (`MarkdownBasicsModal`) and the Settings modal (`SettingsModal`): a light,
/// theme-independent card with a title + circular-close header, presented over a
/// dimming scrim. Centralizing the chrome here keeps the two modals identical and
/// removes the old coupling where `SettingsModal` reached into `MarkdownBasicsModal`'s
/// constants for its palette and metrics.
enum MuseModalChrome {
    /// Theme-independent light-card palette (the card reads the same in dark mode).
    static let backgroundWhiteComponent: CGFloat = 0.98
    static let textRedComponent: CGFloat = 0.12
    static let secondaryTextOpacity: CGFloat = 0.74

    /// Circular close-button fill: invisible at rest, a faint tint on hover.
    static let closeRestingFillOpacity = 0.0
    static let closeHoverFillOpacity = 0.08

    /// Card geometry + entrance motion (shared so both modals animate identically).
    static let cornerRadius: CGFloat = 18
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10

    static var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedWhite: backgroundWhiteComponent, alpha: 1))
    }

    static var primaryTextColor: Color {
        Color(nsColor: NSColor(calibratedRed: textRedComponent, green: textRedComponent, blue: textRedComponent, alpha: 1))
    }

    static var secondaryTextColor: Color {
        primaryTextColor.opacity(secondaryTextOpacity)
    }
}

/// The shared header row for a Muse modal: a semibold title on the left and a
/// circular, Esc-bound close button on the right (invisible until hovered).
struct MuseModalHeader: View {
    var title: String
    var dismiss: () -> Void
    @State private var isCloseHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(MuseModalChrome.primaryTextColor)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MuseModalChrome.secondaryTextColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(MuseModalChrome.primaryTextColor.opacity(isCloseHovered ? MuseModalChrome.closeHoverFillOpacity : MuseModalChrome.closeRestingFillOpacity))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .contentShape(Circle())
            .help("Close")
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isCloseHovered)
        }
    }
}

/// The card container shared by every Muse modal: fixed inner padding, a
/// caller-sized width, the light background, rounded clip + hairline stroke, drop
/// shadow, and a forced-light color scheme so the card matches in either appearance.
private struct MuseModalCard: ViewModifier {
    var width: CGFloat
    var accessibilityLabel: String

    func body(content: Content) -> some View {
        content
            .padding(24)
            .frame(width: width, alignment: .leading)
            .background(MuseModalChrome.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 28, x: 0, y: 14)
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }
}

extension View {
    func museModalCard(width: CGFloat, accessibilityLabel: String) -> some View {
        modifier(MuseModalCard(width: width, accessibilityLabel: accessibilityLabel))
    }
}

struct MarkdownBasicsModal: View {
    struct Example: Identifiable, Equatable {
        var label: String
        var syntax: String

        var id: String { syntax }
    }

    struct Row: Identifiable, Equatable {
        var label: String
        var detail: String

        var id: String { "\(label)-\(detail)" }
    }

    struct Section: Identifiable, Equatable {
        var title: String
        var rows: [Row]

        var id: String { title }
    }

    static let title = "Info"
    static let showsCloseButton = true
    static let dismissesWhenClickingOutside = true
    static let supportsEscapeDismissal = true
    static let usesRowSeparators = true
    static let usesMonospacedExampleFont = false
    static let contentWidth: CGFloat = 560
    // Shared Muse chrome values, forwarded so this modal has a stable surface while
    // `MuseModalChrome` stays the single source of truth for the visual language.
    static let closeRestingFillOpacity = MuseModalChrome.closeRestingFillOpacity
    static let closeHoverFillOpacity = MuseModalChrome.closeHoverFillOpacity
    static let animationDuration = MuseModalChrome.animationDuration
    static let entranceYOffset = MuseModalChrome.entranceYOffset
    static let usesThemeIndependentLightChrome = true
    static let backgroundWhiteComponent = MuseModalChrome.backgroundWhiteComponent
    static let textRedComponent = MuseModalChrome.textRedComponent
    static let secondaryTextOpacity = MuseModalChrome.secondaryTextOpacity
    static let transitionStyle = EditorAuxiliaryTransitionStyle.fadeAndMoveUp
    static let examples = [
        Example(label: "Title", syntax: "# Title"),
        Example(label: "Section", syntax: "## Section"),
        Example(label: "Bold", syntax: "**bold**"),
        Example(label: "Italic", syntax: "_italic_"),
        Example(label: "Bullet", syntax: "- bullet"),
        Example(label: "Numbered", syntax: "1. item"),
        Example(label: "Task", syntax: "- [ ] to do"),
        Example(label: "Done (click to toggle)", syntax: "- [x] done"),
        Example(label: "Quote", syntax: "> quote"),
        Example(label: "Strikethrough", syntax: "~~text~~"),
        Example(label: "Code", syntax: "`code`"),
        Example(label: "Divider", syntax: "---"),
        Example(label: "Link", syntax: "[link](https://example.com)")
    ]
    static let sections = [
        Section(
            title: "Markdown Basics",
            rows: examples.map { Row(label: $0.syntax, detail: $0.label) } + [
                Row(label: "![alt](url)", detail: "An image shows as a labelled placeholder."),
                Row(label: "| a | b |", detail: "A table: a header row, then a |---|---| line under it, then rows. Colons in the dashes (:--, :-:, --:) set column alignment."),
                Row(label: "Block Spacing", detail: "In Read and Preview modes, adds space around Markdown block breaks.")
            ]
        ),
        Section(
            title: "Diagrams",
            rows: [
                Row(label: "```mermaid", detail: "Fence a code block tagged “mermaid” to render a diagram in Read and Preview. Write shows the source; a diagram that can’t be parsed falls back to a labelled source block.")
            ]
        ),
        Section(
            title: "Math",
            rows: [
                Row(label: "$x^2 + y^2$", detail: "Inline LaTeX math between single dollar signs, rendered in the line."),
                Row(label: "$$…$$", detail: "A centered equation block between double dollar signs (put them on their own lines, or wrap a single line)."),
                Row(label: "\\frac{a}{b}", detail: "Standard LaTeX math is supported — fractions, roots, Greek letters, sums, integrals. Renders in Read and Preview; Write shows the source, and invalid math falls back to its source."),
                Row(label: "it costs $5", detail: "Ordinary dollar amounts stay as text — they are not treated as math.")
            ]
        ),
        Section(
            title: "Search",
            rows: [
                Row(label: "Return", detail: "While searching, press Return to jump to the next match. It wraps back to the first.")
            ]
        )
    ]

    /// Height the window actually offers (injected by the container's GeometryReader). The section
    /// list is capped to this so the modal fits and scrolls inside a short window instead of forcing
    /// the window taller.
    var availableHeight: CGFloat = 900
    var dismiss: () -> Void = {}
    @State private var measuredSectionsHeight: CGFloat = 0

    /// Room left for the title, paddings, and top/bottom breathing space around the card.
    private static let verticalChromeAllowance: CGFloat = 180

    /// The scrollable section list is capped to the available window height; when the content is
    /// shorter than the cap the frame hugs it exactly (no empty slack, no scrolling).
    private var maxSectionsHeight: CGFloat {
        max(160, availableHeight - Self.verticalChromeAllowance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MuseModalHeader(title: Self.title, dismiss: dismiss)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.sections) { section in
                        guideSection(section)
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MarkdownGuideHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // Hug the content, but cap the height so a taller guide scrolls instead of clipping
            // off the top/bottom on a short window.
            .frame(height: min(measuredSectionsHeight == 0 ? maxSectionsHeight : measuredSectionsHeight, maxSectionsHeight))
            .onPreferenceChange(MarkdownGuideHeightKey.self) { measuredSectionsHeight = $0 }
        }
        .museModalCard(
            width: Self.contentWidth,
            accessibilityLabel: EditorAuxiliaryPresentation.markdownBasics.accessibilityLabel
        )
    }

    private func guideSection(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MuseModalChrome.primaryTextColor)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    guideRow(row)

                    if Self.usesRowSeparators && index < section.rows.count - 1 {
                        Divider()
                            .overlay(MuseModalChrome.primaryTextColor.opacity(0.08))
                    }
                }
            }
        }
    }

    private func guideRow(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(row.label)
                .font(.body)
                .foregroundStyle(MuseModalChrome.primaryTextColor)
                .frame(width: 172, alignment: .leading)

            Text(row.detail)
                .font(.body)
                .foregroundStyle(MuseModalChrome.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

struct MarkdownBasicsOverlay: View {
    static let scrimOpacity = 0.32
    static let scrimTransitionStyle = EditorAuxiliaryTransitionStyle.instant

    var dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(Self.scrimOpacity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditorModeSegmentedControl: View {
    struct LiquidBridge: Equatable {
        var from: EditorDisplayMode
        var to: EditorDisplayMode
    }

    static let segmentWidth: CGFloat = 78
    static let segmentHeight: CGFloat = 30
    static let selectedFillRedComponent: CGFloat = 0.86
    static let backgroundFillRedComponent: CGFloat = 1.0
    static let textFillRedComponent: CGFloat = 0.18
    static let darkSelectedFillRedComponent: CGFloat = 0.20
    static let darkBackgroundFillRedComponent: CGFloat = (LineformColors.darkControlBackground.usingColorSpace(.sRGB) ?? LineformColors.darkControlBackground).redComponent
    static let darkTextFillRedComponent: CGFloat = 0.92
    static let shadowRadius: CGFloat = 5
    static let hitAreaWidth: CGFloat = segmentWidth
    static let hitAreaHeight: CGFloat = segmentHeight
    static let dividerSlotWidth: CGFloat = 3
    static let liquidSettleDelay: TimeInterval = 0.16
    static let usesReduceMotionForLiquidBridge = true

    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false
    var reduceMotion = false

    @State private var hoveredMode: EditorDisplayMode?
    @State private var liquidBridge: LiquidBridge?
    @State private var liquidTransitionID = 0

    private let modes = EditorDisplayMode.allCases
    private let controlPadding: CGFloat = 3

    var body: some View {
        ZStack(alignment: .leading) {
            hoverPill
            selectedPill

            HStack(spacing: 0) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    Button {
                        select(mode)
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Self.textFillColor(usesDarkChrome: usesDarkChrome))
                            .lineLimit(1)
                            .frame(width: Self.hitAreaWidth, height: Self.hitAreaHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                    .onHover { isHovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredMode = isHovering ? mode : nil
                        }
                    }

                    if index < modes.index(before: modes.endIndex) {
                        Rectangle()
                            .fill(Self.dividerColor(usesDarkChrome: usesDarkChrome).opacity(shouldShowDivider(after: index) ? 0.45 : 0))
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 1)
                    }
                }
            }
        }
        .padding(controlPadding)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Self.backgroundFillColor(usesDarkChrome: usesDarkChrome).opacity(usesDarkChrome ? 0.92 : 0.82))
                }
                .overlay {
                    Capsule()
                        .stroke((usesDarkChrome ? Color.white.opacity(0.10) : Color.white.opacity(0.72)), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.035), radius: Self.shadowRadius, y: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor mode")
    }

    private var selectedPill: some View {
        Capsule()
            .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome))
            .overlay {
                Capsule()
                    .stroke((usesDarkChrome ? Color.white.opacity(0.16) : Color.white.opacity(0.36)), lineWidth: 0.5)
            }
            .frame(width: selectedPillWidth, height: Self.segmentHeight)
            .offset(x: selectedPillOffset)
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.30, dampingFraction: 0.82), reduceMotion: reduceMotion),
                value: selection
            )
            .animation(
                EditorMotionPolicy.animation(.spring(response: 0.24, dampingFraction: 0.78), reduceMotion: reduceMotion),
                value: liquidBridge
            )
    }

    @ViewBuilder
    private var hoverPill: some View {
        if let hoveredMode, hoveredMode != selection {
            Capsule()
                .fill(Self.selectedFillColor(usesDarkChrome: usesDarkChrome).opacity(0.48))
                .frame(width: Self.segmentWidth, height: Self.segmentHeight)
                .offset(x: Self.segmentOffset(for: hoveredMode))
                .transition(.opacity)
        }
    }

    private var selectedPillWidth: CGFloat {
        if let liquidBridge {
            return Self.liquidPillWidth(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentWidth
    }

    private var selectedPillOffset: CGFloat {
        if let liquidBridge {
            return Self.liquidPillOffset(from: liquidBridge.from, to: liquidBridge.to)
        }

        return Self.segmentOffset(for: selection)
    }

    private static func selectedFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkSelectedFillRedComponent : selectedFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: usesDarkChrome ? 0.92 : 0.74
            )
        )
    }

    private static func backgroundFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkBackgroundFillRedComponent : backgroundFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func textFillColor(usesDarkChrome: Bool) -> Color {
        let component = usesDarkChrome ? darkTextFillRedComponent : textFillRedComponent
        return Color(
            nsColor: NSColor(
                calibratedRed: component,
                green: component,
                blue: component,
                alpha: 1
            )
        )
    }

    private static func dividerColor(usesDarkChrome: Bool) -> Color {
        usesDarkChrome ? .white : Color(nsColor: .separatorColor)
    }

    static func segmentOffset(for mode: EditorDisplayMode) -> CGFloat {
        guard let index = EditorDisplayMode.allCases.firstIndex(of: mode) else {
            return 0
        }

        return CGFloat(index) * (Self.segmentWidth + Self.dividerSlotWidth)
    }

    static func liquidPillOffset(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        min(segmentOffset(for: source), segmentOffset(for: destination))
    }

    static func liquidPillWidth(from source: EditorDisplayMode, to destination: EditorDisplayMode) -> CGFloat {
        abs(segmentOffset(for: destination) - segmentOffset(for: source)) + Self.segmentWidth
    }

    private func select(_ mode: EditorDisplayMode) {
        guard mode != selection else {
            return
        }

        guard !reduceMotion else {
            liquidTransitionID += 1
            liquidBridge = nil
            selection = mode
            return
        }

        let previousSelection = selection
        liquidTransitionID += 1
        let transitionID = liquidTransitionID

        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            liquidBridge = LiquidBridge(from: previousSelection, to: mode)
            selection = mode
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liquidSettleDelay) {
            guard transitionID == liquidTransitionID else {
                return
            }

            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                liquidBridge = nil
            }
        }
    }

    private func shouldShowDivider(after index: Int) -> Bool {
        guard index < modes.index(before: modes.endIndex) else {
            return false
        }

        let nextIndex = modes.index(after: index)
        return modes[index] != selection && modes[nextIndex] != selection
    }
}

struct WindowChromeReader: NSViewRepresentable {
    @Binding var windowNumber: Int?
    var usesDarkChrome: Bool

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.usesDarkChrome = usesDarkChrome
        view.onWindowChanged = { window in
            // Read the window number a runloop LATER: an off-screen window (before it is
            // ordered front) reports 0/-1, and the @Binding write must not happen during
            // the SwiftUI view-update phase. Deferring the read (as the old code did) lets
            // it settle to the real on-screen number and reset to nil when the view
            // detaches. The appearance itself is applied synchronously (in ChromeView) so
            // native, appearance-derived controls never paint a frame against the default
            // light appearance.
            Task { @MainActor in windowNumber = window?.windowNumber }
        }
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.usesDarkChrome = usesDarkChrome
        nsView.applyChrome()
    }

    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) {
        nsView.window?.appearance = nil
        nsView.window?.contentView?.appearance = nil
    }

    /// Applies the window appearance SYNCHRONOUSLY the moment it joins a window (and on
    /// later theme changes), rather than deferring it inside the Task used for the
    /// windowNumber binding. Deferring the appearance let the window render a frame with
    /// the default (light) appearance, so appearance-derived native controls — the
    /// NavigationSplitView sidebar-toggle glyph and NSColor.secondaryLabelColor in the
    /// empty-state placeholder — flashed dark-on-dark in the Quiet theme.
    final class ChromeView: NSView {
        var usesDarkChrome = false
        var onWindowChanged: ((NSWindow?) -> Void)?
        private weak var appliedWindow: NSWindow?
        private var appliedDarkChrome: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome()
        }

        func applyChrome() {
            // Apply synchronously, but only when the window or theme actually changed —
            // re-setting an identical appearance on every unrelated SwiftUI update would
            // force a redundant appearance recalc during the update phase (a re-entrancy
            // risk) for no benefit. The first application happens in viewDidMoveToWindow,
            // an AppKit callback outside SwiftUI's update phase.
            if let window, window !== appliedWindow || appliedDarkChrome != usesDarkChrome {
                appliedWindow = window
                appliedDarkChrome = usesDarkChrome
                window.animationBehavior = .none
                EditorWindowChrome.apply(to: window, usesDarkChrome: usesDarkChrome)
            }
            // Report the (possibly nil) window every time so the deferred reader converges
            // on the real number once the window is ordered and clears it on detach.
            onWindowChanged?(window)
        }
    }
}

struct EditorWindowChrome {
    static func appearanceName(usesDarkChrome: Bool) -> NSAppearance.Name {
        usesDarkChrome ? .darkAqua : .aqua
    }

    static func appearance(usesDarkChrome: Bool) -> NSAppearance? {
        NSAppearance(named: appearanceName(usesDarkChrome: usesDarkChrome))
    }

    @MainActor
    static func apply(to window: NSWindow?, usesDarkChrome: Bool) {
        let resolvedAppearance = appearance(usesDarkChrome: usesDarkChrome)
        window?.appearance = resolvedAppearance
        window?.contentView?.appearance = resolvedAppearance
    }
}
