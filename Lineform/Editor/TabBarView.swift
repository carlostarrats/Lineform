import SwiftUI

/// Document tab bar (redesigned from live QA, 2026-07-18). Flat capsule tabs, no
/// translucency:
/// - Equal-width capsule tabs always filling the bar edge to edge.
/// - The STRIP is the theme page color itself (no bar tone, no separators) so the capsules
///   float on one continuous surface shared with the nav above and the page below.
/// - Light-mode fills derive from the page color (`lightTone`), so Original stays neutral
///   grey while Paper/Calm tint. Inactive tabs are the LIGHTER capsule, the selected tab the
///   DARKER capsule (with a soft shadow) — the reverse of the first pass; the active/hover
///   fills are as dark as WCAG AA allows for their titles (guarded by
///   `testTabColorsMeetAAAgainstTheirFillsInEveryTheme`). Dark chrome keeps fixed dark tones,
///   with inactive capsules a step darker than the page so they stay delineated.
/// - Hovering darkens the capsule and darkens its title (a selection preview); an inactive
///   hover also reveals a close × at the capsule's LEFT. No × at rest, none on a lone tab.
struct TabBarView: View {
    @ObservedObject var tabStore: EditorTabStore
    @ObservedObject var documentSaveStatus: DocumentSaveStatus
    let usesDarkChrome: Bool
    // The theme's page color; light-chrome fills derive from it so Paper/Calm tint the
    // strip and tabs (see lightTone). Nil (tests/previews) falls back to the design greys.
    var pageBackground: NSColor?
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void

    @State private var hoveredTabID: UUID?
    @State private var hoveredCloseTabID: UUID?

    var body: some View {
        HStack(spacing: Self.tabGap) {
            ForEach(Array(tabStore.tabs.enumerated()), id: \.element.id) { _, tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, Self.barHorizontalPadding)
        .padding(.vertical, Self.capsuleVerticalInset)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        // ignoresSafeAreaEdges: [] is load-bearing: as the topmost view in the detail column,
        // a default .background(color) BLEEDS into the top safe area — under the translucent
        // toolbar — so the nav sampled this strip's grey instead of the theme page color the
        // moment a second tab appeared (pixel-verified 2026-07-18: Paper's cream nav went
        // neutral white with tabs, identical no-tab nav stayed cream). Constrained to the
        // bar's own bounds, the page-color background on editorShell's wrapper owns the
        // under-toolbar region, so the nav is identical with or without tabs.
        .background(
            Color(nsColor: Self.barBackgroundColor(usesDarkChrome: usesDarkChrome, pageBackground: pageBackground)),
            ignoresSafeAreaEdges: []
        )
    }

    // Design metrics (Paper, 1:1): bar 32, capsule 24, 4 inset, ~3 gap, 4 edge padding.
    static let barHeight: CGFloat = 32
    static let capsuleVerticalInset: CGFloat = 4
    static let tabGap: CGFloat = 3
    static let barHorizontalPadding: CGFloat = 4

    @ViewBuilder
    private func tabButton(for tab: DocumentTab) -> some View {
        let isSelected = tab.id == tabStore.selectedTabID
        let isHovered = hoveredTabID == tab.id
        // `hasUnsavedWork`, NOT the narrower `isDirty`: "does this tab hold unsaved work" is one
        // concept, and every other consumer (the close-tab prompt, the close-window sheet, the
        // NSDocument isEdited sync) reads it from there. Reading `isDirty` here left two cases
        // with no dot on a tab whose text is the only copy of its content — an untitled tab with
        // typed content, and a tab whose file was trashed from the Files sidebar (which nils the
        // tab's fileURL while the save baseline still says clean).
        let isDirty = tab.hasUnsavedWork(documentSaveStatus: documentSaveStatus)
        // The × exists only under the pointer (design: no close affordance at rest,
        // including on the selected tab) and never on a lone tab.
        let showsClose = tabStore.tabCount > 1 && isHovered

        ZStack {
            // Selection tap area: covers the whole capsule so the close button can be a
            // sibling Button instead of nested inside another Button. A real Button
            // (rather than onTapGesture) because onTapGesture can lose gesture-priority
            // races on macOS, silently swallowing clicks — Button routes through AppKit's
            // normal control click handling instead.
            Button {
                onSelectTab(tab.id)
            } label: {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: Self.tabBackgroundColor(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        usesDarkChrome: usesDarkChrome,
                        pageBackground: pageBackground
                    )))
                    // Design: 0/1/2 (spread 1) black 8% under the selected capsule only.
                    .shadow(
                        color: Color.black.opacity(isSelected ? 0.08 : 0),
                        radius: 1, x: 0, y: 1
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tab.title))
            // `Text(verbatim:)` on the empty branch: a bare `Text("")` is a string literal, so
            // SwiftUI takes it as a LocalizedStringKey and the empty string is extracted into the
            // catalog as a key nothing can translate.
            .accessibilityValue(isSelected ? Text("selected") : Text(verbatim: ""))
            // The visible × is deliberately pointer-hover-only (design: no close affordance
            // at rest). VoiceOver / Switch Control users reach close through this custom
            // action instead — same gating as the visible ×: only when more than one tab is
            // open (closing a lone tab is not a tab operation).
            .accessibilityActions {
                if tabStore.tabCount > 1 {
                    Button("Close tab") { onCloseTab(tab.id) }
                }
            }

            // Centered title cluster (title is centered regardless of the left ×).
            HStack(spacing: 6) {
                if isDirty {
                    Circle()
                        .fill(Color(nsColor: Self.dirtyDotColor(usesDarkChrome: usesDarkChrome)))
                        .frame(width: 5, height: 5)
                        .allowsHitTesting(false)
                }

                Text(tab.title)
                    .font(.system(size: 10, weight: .medium))
                    .kerning(0.3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color(nsColor: Self.textColor(usesDarkChrome: usesDarkChrome, isSelected: isSelected, isHovered: isHovered)))
                    // Text still consumes hits at its own bounds even with no gesture
                    // attached, which silently blocks the selection Button stacked behind
                    // it. Let clicks fall through to the Button underneath.
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 28)

            // Close × pinned to the capsule's left edge, per the design's hover frames.
            if showsClose {
                HStack {
                    closeButton(for: tab.id)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }
        }
        // Equal-width distribution: every tab takes the same share of the full bar.
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight - Self.capsuleVerticalInset * 2)
        .onHover { hovering in
            // Same quiet transition as the Write/Read/Preview control's hover fill —
            // the capsule tint, separator fade, and × appearance all ride this animation.
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
            }
        }
    }

    @ViewBuilder
    private func closeButton(for tabID: UUID) -> some View {
        Button {
            onCloseTab(tabID)
        } label: {
            // The × is drawn as raw geometry, not an SF Symbol — the symbol's internal
            // bearings kept it optically off-center inside the hover circle no matter
            // how it was stacked. Two strokes in a square, centered by construction.
            Circle()
                .fill(Color(nsColor: Self.closeButtonHoverCircleColor(usesDarkChrome: usesDarkChrome)))
                .opacity(hoveredCloseTabID == tabID ? 1 : 0)
                .frame(width: 16, height: 16)
                .overlay(
                    TabCloseGlyph()
                        .stroke(
                            Color(nsColor: Self.closeButtonColor(usesDarkChrome: usesDarkChrome)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                        )
                        .frame(width: 7, height: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredCloseTabID = hovering ? tabID : (hoveredCloseTabID == tabID ? nil : hoveredCloseTabID)
            }
        }
        .accessibilityLabel("Close tab")
    }

    // Design values (light chrome, from the Paper file): bar #E3E3E3; inactive tabs
    // share it; hover #D3D3D3; selected #EBEBEB (+slight tint when also hovered);
    // text #4C4C4C everywhere; separator #CDCDCD; × glyph #7A7A7A. Dark chrome maps
    // the same relationships onto the app's dark bar tones.
    //
    // In light chrome the fills are derived from the theme PAGE color, not fixed greys:
    // each design grey becomes `page × (grey/255)`, so a pure-white page (Original)
    // yields exactly the designed grey while Paper's cream and Calm's cool tint carry
    // into the strip and tabs instead of reading as neutral grey on a tinted page.
    private static func lightTone(_ factor: CGFloat, page: NSColor?) -> NSColor {
        guard let rgb = page?.usingColorSpace(.sRGB) else {
            return NSColor(srgbRed: factor, green: factor, blue: factor, alpha: 1)
        }
        return NSColor(
            srgbRed: rgb.redComponent * factor,
            green: rgb.greenComponent * factor,
            blue: rgb.blueComponent * factor,
            alpha: 1
        )
    }

    // The strip is the PAGE surface itself (QA 2026-07-18): the bar carries no tone of its
    // own in any theme, so the tab capsules float directly on one continuous page-colored
    // surface with the nav above and the page below. Nil (tests/previews) falls back to
    // the page-equivalent defaults.
    static func barBackgroundColor(usesDarkChrome: Bool, pageBackground: NSColor? = nil) -> NSColor {
        pageBackground ?? (usesDarkChrome ? NSColor(calibratedWhite: 0.19, alpha: 1) : .white)
    }

    static func tabBackgroundColor(isSelected: Bool, isHovered: Bool, usesDarkChrome: Bool, pageBackground: NSColor? = nil) -> NSColor {
        if isSelected {
            if isHovered {
                // 0xBE is the darkest hover step that keeps the #444444 title ≥4.5:1 on Paper.
                return usesDarkChrome
                    ? NSColor(calibratedWhite: 0.27, alpha: 1)
                    : lightTone(0xBE / 255, page: pageBackground)
            }
            // Light SELECTED is the DARK capsule (QA 2026-07-18, reversed from the original
            // design): 0xC6 is the darkest tone that keeps the selected title (#444444, see
            // textColor) at ≥4.5:1 WCAG AA on the dimmest light page (Paper's cream) — fill
            // ≈0.49 luminance vs text ≈0.058 → 5.0:1 there, 5.5:1 on a white page. Darkening
            // further drops Paper below AA. Dark selected stepped 0.30 → 0.26 per QA.
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.26, alpha: 1)
                : lightTone(0xC6 / 255, page: pageBackground)
        }
        if isHovered {
            // Light hover mirrors dark's clearly-visible shift (QA 2026-07-18): 0xF0 → 0xE0
            // (0xDA read a touch too dark in QA), with the hovered title darkening to
            // #444444 (see textColor) so the pair holds ≥6:1.
            return usesDarkChrome
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : lightTone(0xE0 / 255, page: pageBackground)
        }
        // Resting INACTIVE tabs (QA 2026-07-18, reversed from the original design): the
        // LIGHT capsule (0xF0 — the tone the selected tab used to carry; #636363 text holds
        // 4.8:1 on Paper). Dark chrome: 0.16 against the ~0.19 page — clearly darker than
        // the background without vanishing into it.
        return usesDarkChrome
            ? NSColor(calibratedWhite: 0.16, alpha: 1)
            : lightTone(0xF0 / 255, page: pageBackground)
    }

    static func textColor(usesDarkChrome: Bool, isSelected: Bool = false, isHovered: Bool = false) -> NSColor {
        if usesDarkChrome {
            return NSColor(calibratedWhite: 0.78, alpha: 1)
        }
        // Selected rides the DARK 0xC6 capsule and needs the darker #444444 to hold WCAG AA
        // (see tabBackgroundColor); a HOVERED inactive tab darkens to its 0xDA fill and takes
        // the same darker title (reads as a selection preview and keeps ≥6:1). Resting
        // inactive keeps the quieter #636363 on its light capsule.
        return (isSelected || isHovered)
            ? NSColor(srgbRed: 0x44 / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
            : NSColor(srgbRed: 0x63 / 255, green: 0x63 / 255, blue: 0x63 / 255, alpha: 1)
    }

    static func dirtyDotColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.75, alpha: 1)
            : NSColor(srgbRed: 0x4C / 255, green: 0x4C / 255, blue: 0x4C / 255, alpha: 1)
    }

    static func closeButtonColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(calibratedWhite: 0.60, alpha: 1)
            : NSColor(srgbRed: 0x5E / 255, green: 0x5E / 255, blue: 0x5E / 255, alpha: 1)
    }

    /// An × as exact geometry: both diagonals of the given rect.
    struct TabCloseGlyph: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            return path
        }
    }

    static func closeButtonHoverCircleColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.08)
    }
}
