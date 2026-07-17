import SwiftUI

struct EditorAuxiliaryPresentation: Equatable {
    enum Kind: Equatable {
        case nativeInspector
        case trailingDrawer
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
}

enum EditorAuxiliaryPresenter: Equatable {
    case systemInspector
    case customLayout
}

enum EditorAuxiliaryTransitionStyle: Equatable {
    case instant
    case systemInspector
    case slideAndFade
}

/// Shared visual language for Lineform's in-window "Muse-style" modal — the Settings
/// modal (`SettingsModal`): a light, theme-independent card with a title +
/// circular-close header, presented over a dimming scrim (`MuseModalScrim`).
/// Centralizing the chrome here keeps the modal's look stable and reusable.
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

/// The dimming, tap-to-dismiss scrim behind a Muse-style modal (Settings). Shared
/// chrome — the modal card is layered above it by `museModalLayer`.
struct MuseModalScrim: View {
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
        // The editor's I-beam gets "stuck" when the modal covers the window (nothing over the
        // scrim resets it). Actively reassert the arrow as the pointer moves across the scrim.
        .modalArrowCursor()
    }
}

extension View {
    /// Actively sets the arrow cursor while the pointer moves within this view. Used on modal
    /// surfaces (scrim + card) so the editor's I-beam doesn't linger over them.
    func modalArrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase {
                NSCursor.arrow.set()
            }
        }
    }
}

/// The toolbar's principal mode control, self-adapting to window width: the wide segmented
/// control normally, the compact labeled menu below
/// `EditorToolbarCompactPresentation.compactModeControlThreshold`. The width observation and the
/// compact flag live HERE, in this small view, so a threshold crossing re-renders only this
/// control — putting that state on `EditorContainerView` re-rendered the whole editor mid-drag,
/// which visibly disturbed the editor's scroll anchoring.
struct EditorModePrincipalControl: View {
    @Binding var selection: EditorDisplayMode
    var windowNumber: Int?
    var usesDarkChrome = false
    var reduceMotion = false
    /// When set, the compact menu also carries a "Reading Experience" row — at compact widths the
    /// separate Aa toolbar button is hidden entirely (EditorReadingExperienceToolbarButton), so
    /// the native "»" overflow can only ever contain ONE uniform native menu item.
    var openReadingExperience: (() -> Void)?

    @State private var usesCompactControl = false

    var body: some View {
        Group {
            if usesCompactControl {
                EditorModeCompactMenu(
                    selection: $selection,
                    usesDarkChrome: usesDarkChrome,
                    openReadingExperience: openReadingExperience
                )
            } else {
                EditorModeSegmentedControl(
                    selection: $selection,
                    usesDarkChrome: usesDarkChrome,
                    reduceMotion: reduceMotion
                )
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: windowNumber) { _, _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            refresh()
        }
    }

    private func refresh() {
        guard
            let windowNumber,
            let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber })
        else {
            return
        }

        let compact = EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: window.frame.width)
        // Write state only on a threshold crossing, never per resize tick.
        if compact != usesCompactControl {
            usesCompactControl = compact
        }
    }
}

/// The Aa (Reading Experience) toolbar button, hidden at compact widths — its action lives in the
/// compact mode menu there instead, so no bare icon can ever land in the "»" overflow popover.
struct EditorReadingExperienceToolbarButton<Content: View>: View {
    var windowNumber: Int?
    @ViewBuilder var content: () -> Content

    @State private var isCompact = false

    var body: some View {
        Group {
            if !isCompact {
                content()
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: windowNumber) { _, _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard (notification.object as? NSWindow)?.windowNumber == windowNumber else {
                return
            }
            refresh()
        }
    }

    private func refresh() {
        guard
            let windowNumber,
            let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber })
        else {
            return
        }

        let compact = EditorToolbarCompactPresentation.usesCompactModeControl(windowWidth: window.frame.width)
        if compact != isCompact {
            isCompact = compact
        }
    }
}

/// The narrow-window stand-in for `EditorModeSegmentedControl`: a compact labeled menu showing
/// the current mode with a native pulldown of all three, so the toolbar never overflows our
/// custom control into the clipped "»" popover.
struct EditorModeCompactMenu: View {
    @Binding var selection: EditorDisplayMode
    var usesDarkChrome = false
    var openReadingExperience: (() -> Void)?

    var body: some View {
        Menu {
            Picker("Editor mode", selection: $selection) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)

            if let openReadingExperience {
                Divider()
                Button("Reading Experience") {
                    openReadingExperience()
                }
            }
        } label: {
            // No custom font: the label must inherit the system menu/toolbar typography so the
            // "»" overflow popover renders it at the same size as every other native row.
            Text(selection.title)
                .foregroundStyle(
                    EditorToolbarTogglePresentation.offIconColor(usesDarkChrome: usesDarkChrome)
                )
        }
        .menuIndicator(.visible)
        .fixedSize()
        // EXACTLY the segmented control's total height. The toolbar derives its height from its
        // tallest item, so swapping in a shorter control mid-drag changed the toolbar height and
        // vertically snapped the ENTIRE content area (~65pt) at the compact threshold — the
        // "text jumps up when resizing" the user kept reporting after the scroll fixes landed;
        // caught on a screen recording of the real drag (2026-07-17). Same-height controls keep
        // the toolbar, and therefore the page, rock still across the swap.
        .frame(height: EditorModeSegmentedControl.segmentHeight + 6)
        .accessibilityLabel("Editor mode")
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
            // Apply synchronously when the window or theme changed — OR when the window's
            // appearance has drifted from what the theme wants. The drift check is load-bearing
            // for multi-tab: when the tab bar appears (1→2 tabs) the detail hierarchy rebuilds and
            // AppKit can reset the window's explicit appearance back to the default (light) aqua,
            // which on a dark theme leaves the toolbar/title bar light while the content stays
            // dark. Re-asserting only on window/theme change missed that (neither changed), so the
            // light header stuck. Re-applying on drift self-heals it and cannot loop: once applied,
            // the appearance matches and the guard no longer fires.
            if let window {
                let desiredName = EditorWindowChrome.appearanceName(usesDarkChrome: usesDarkChrome)
                let appearanceDrifted = window.appearance?.name != desiredName
                if window !== appliedWindow || appliedDarkChrome != usesDarkChrome || appearanceDrifted {
                    appliedWindow = window
                    appliedDarkChrome = usesDarkChrome
                    window.animationBehavior = .none
                    EditorWindowChrome.apply(to: window, usesDarkChrome: usesDarkChrome)
                }
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
