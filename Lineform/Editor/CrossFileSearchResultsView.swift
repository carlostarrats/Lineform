import SwiftUI

/// The All Files search results page: a transient, READ-ONLY layer over the current tab's
/// content area (never a floating card — that was explicitly rejected in brainstorming as
/// convoluted). Opaque theme background, editor-family typography, a responsive grid of
/// equal-height cards (one per matching file) so the page fills the available width and
/// wraps down to a single stacked column as the window narrows. Clicking a card is a
/// sidebar-click-equivalent open; Esc dismisses. This view never takes text input — typing
/// stays in the toolbar search field.
struct CrossFileSearchResultsView: View {
    let query: String
    let results: [CrossFileSearchResult]
    let isSearching: Bool
    let theme: Theme
    var onOpen: (CrossFileSearchResult) -> Void
    var onDismiss: () -> Void

    @State private var hoveredResultID: String?

    static let cardHeight: CGFloat = 220

    // User's design-file values, shared with the sidebar chrome (side-sheet background /
    // hairline stroke / snippet-pill fill / muted text). Two fixed variants keyed on
    // `theme.usesDarkChrome` — same approach as QuickOpenPalette / the Find & Replace card —
    // not per-theme tinting.
    private static let lightCardFill = Color(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFC / 255)
    private static let lightCardStroke = Color(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE4 / 255)
    private static let lightPillFill = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    private static let mutedTextColor = Color(red: 0x78 / 255, green: 0x78 / 255, blue: 0x78 / 255)

    private var usesDarkChrome: Bool { theme.usesDarkChrome }
    private var primaryColor: Color { Color(nsColor: theme.textColor) }
    private var secondaryColor: Color { usesDarkChrome ? primaryColor.opacity(0.55) : Self.mutedTextColor }

    private var cardFill: Color {
        usesDarkChrome ? Color(white: 0.15) : Self.lightCardFill
    }

    private var cardStroke: Color {
        usesDarkChrome ? Color.white.opacity(0.14) : Self.lightCardStroke
    }

    private var pillFill: Color {
        usesDarkChrome ? Color.white.opacity(0.08) : Self.lightPillFill
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.backgroundColor))
        // The editor NSTextView underneath leaves its I-beam behind when this page covers
        // it (its cursorUpdate never fires over an overlay) — reassert the arrow the same
        // way the app's modals do.
        .modalArrowCursor()
        .onExitCommand { onDismiss() }
        .accessibilityLabel("All files search results")
    }

    private var header: some View {
        Text(headerText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondaryColor)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Search All Files" }
        if isSearching && results.isEmpty { return "Searching…" }
        let files = results.count == 1 ? "1 file" : "\(results.count) files"
        return "\(files) matching \u{201C}\(trimmed)\u{201D}"
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hint("Type to search all files…")
        } else if results.isEmpty && !isSearching {
            hint("No matches in any file.")
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(results) { result in
                    resultCard(result)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(secondaryColor)
    }

    private func resultCard(_ result: CrossFileSearchResult) -> some View {
        let isHovered = hoveredResultID == result.id
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                cardHeader(result)
                Text(locationText(result))
                    .font(.system(size: 10.5))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom, 12)
            // A real NSScrollView (see the page-level comment): AppKit delivers the wheel
            // to the scroll view under the cursor, so pills scroll inside the card.
            AppKitVerticalScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                        Text(snippetText(snippet))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(pillFill)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clicks land on the AppKit hosting view, not the SwiftUI card behind it,
                // so the pills area needs its own open gesture to keep "click anywhere on
                // the card opens the file" true.
                .contentShape(Rectangle())
                .onTapGesture { onOpen(result) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .frame(height: Self.cardHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same recipe as QuickOpenPalette/MuseModalCard: flat fill, clip, hairline stroke,
        // then the shadow applied to the CLIPPED shape (shadowing the background directly
        // reads blurry/muddy).
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(primaryColor.opacity(isHovered ? 0.04 : 0))
        )
        .shadow(color: Color.black.opacity(0.09), radius: 6, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { onOpen(result) }
        .onHover { hovering in
            hoveredResultID = hovering ? result.id : (hoveredResultID == result.id ? nil : hoveredResultID)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText(result))
    }

    private func cardHeader(_ result: CrossFileSearchResult) -> some View {
        HStack(spacing: 8) {
            Text(result.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches")
                .font(.system(size: 10.5))
                .foregroundStyle(secondaryColor)
        }
    }

    /// The file's directory within its root — never repeats the filename. A root-level
    /// file (relativePath == name) shows the root title instead.
    private func locationText(_ result: CrossFileSearchResult) -> String {
        if result.relativePath == result.name {
            return result.rootTitle
        }
        let directory = (result.relativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? result.rootTitle : directory
    }

    /// The snippet line with the matched substring emphasized (semibold, primary color).
    private func snippetText(_ snippet: CrossFileSearchSnippet) -> AttributedString {
        // The base font/color are set as attributes on the FULL string, not as a `.font()`/
        // `.foregroundStyle()` modifier on the Text view: a whole-view modifier overrides
        // per-run attributes on a Text(AttributedString), which silently stomped the match
        // run's semibold weight. Setting both base and match-run attributes directly on the
        // AttributedString lets the match run's bold survive.
        var attributed = AttributedString(snippet.lineText)
        attributed.font = .system(size: 11.5)
        attributed.foregroundColor = secondaryColor
        let nsLine = snippet.lineText as NSString
        guard snippet.matchRange.location != NSNotFound,
              NSMaxRange(snippet.matchRange) <= nsLine.length,
              let range = Range(snippet.matchRange, in: attributed) else {
            return attributed
        }
        attributed[range].font = .system(size: 11.5, weight: .semibold)
        attributed[range].foregroundColor = primaryColor
        return attributed
    }

    private func accessibilityText(_ result: CrossFileSearchResult) -> String {
        let matches = result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
        return "\(result.name), \(locationText(result)), \(matches)"
    }
}

/// AppKit-backed vertical scroller for each card's snippet pills. A real NSScrollView
/// receives the wheel for the area under the cursor directly from AppKit, and — the part
/// that actually broke — its document is sized by content (`intrinsicContentSize`), so
/// overflowing pills genuinely scroll instead of compressing to fit the card. The page
/// around it stays an ordinary SwiftUI ScrollView (an AppKit page scroller was tried and
/// mis-laid-out the LazyVGrid — lazy containers don't report a usable intrinsic height).
/// Transparent background, arrow document cursor so the page's cursor policy holds.
private struct AppKitVerticalScrollView<Content: View>: NSViewRepresentable {
    let showsScroller: Bool
    let content: Content

    init(showsScroller: Bool = false, @ViewBuilder content: () -> Content) {
        self.showsScroller = showsScroller
        self.content = content()
    }

    final class Coordinator {
        var monitor: Any?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // SwiftUI's native page ScrollView claims wheel events at hit-test level before
        // AppKit routing ever reaches this nested scroll view (verified empirically: the
        // event lands in SwiftUI's PlatformGroupContainer and the page scrolls; the card
        // never does). A local monitor sees the event first: if it is over this card and
        // the card can scroll in that direction, the card consumes it; otherwise the
        // event passes through untouched and the page scrolls as usual.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak scrollView] event in
            guard let scrollView, let window = scrollView.window, event.window === window else { return event }
            let locationInScroll = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(locationInScroll),
                  let documentView = scrollView.documentView else { return event }
            let clipView = scrollView.contentView
            let maxOffset = max(0, documentView.frame.height - clipView.bounds.height)
            guard maxOffset > 0 else { return event }
            let current = clipView.bounds.origin.y
            let scrollingDown = event.scrollingDeltaY < 0
            let canConsume = scrollingDown ? current < maxOffset : current > 0
            guard canConsume else { return event }
            scrollView.scrollWheel(with: event)
            return nil
        }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = showsScroller
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView.documentCursor = .arrow

        let hostingView = NSHostingView(rootView: content)
        // The document must be sized by its CONTENT height, not fitted to available
        // bounds: the default sizing options let the hosting view compress to the clip
        // view's height, which left every card with document == viewport (nothing to
        // scroll — the pills silently dropped instead of overflowing).
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        // Pin the document to the clip view's edges (top-anchored; NSHostingView is
        // flipped, so content grows downward) and match widths so pills fill the card.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hostingView = scrollView.documentView as? NSHostingView<Content> else {
            return
        }
        hostingView.rootView = content
    }
}
