import SwiftUI

/// The ⌘K "Jump to File" palette: a centered modal card with a search field over a
/// live-filtered, keyboard-navigable list of every file the sidebar's store has scanned.
/// Pure presentation — flatten/rank logic lives in QuickOpenIndex; opening goes through
/// the same path as a sidebar click (the container's openSidebarFile).
struct QuickOpenPalette: View {
    let entries: [QuickOpenEntry]
    @Binding var query: String
    var usesDarkChrome: Bool
    var availableWidth: CGFloat
    var onOpen: (QuickOpenEntry) -> Void
    var onDismiss: () -> Void

    @State private var selectionIndex = 0
    @FocusState private var isFieldFocused: Bool

    static let maximumCardWidth: CGFloat = 400
    static let listMaximumHeight: CGFloat = 300
    /// Approximate laid-out height of one result row (13pt line + vertical padding),
    /// used to size the scroll area to its content so the card grows with results
    /// instead of always reserving the full maximum height.
    static let estimatedRowHeight: CGFloat = 29

    private var results: [QuickOpenEntry] {
        QuickOpenIndex.search(entries, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    // Matches the light tint of the rows' folder-path text.
                    .foregroundStyle(Color.secondary.opacity(0.55))

                TextField("Jump to file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFieldFocused)
                    .onSubmit { openSelection() }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .accessibilityLabel("Jump to file")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            resultsList
        }
        // The SHARED modal card (MuseModalCard) — same background, radius, outline and
        // shadow as Settings. This used to be a hand-rolled copy of that recipe, which is
        // how the two modals drifted apart; do not re-inline it here.
        .museModalCard(
            width: min(Self.maximumCardWidth, max(280, availableWidth - 48)),
            accessibilityLabel: "Jump to File",
            // The rows and search field carry their own padding.
            padding: 0,
            usesDarkChrome: usesDarkChrome
        )
        .modalArrowCursor()
        .onExitCommand { onDismiss() }
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in
            selectionIndex = 0
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = results
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hintRow("Type to search files…")
        } else if results.isEmpty {
            hintRow("No matches")
        } else {
            // ScrollView greedily fills its maxHeight even with two rows, which left the
            // card tall and empty; cap the frame at the CONTENT's estimated height so the
            // card hugs small result sets and only grows (then scrolls) as matches do.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            resultRow(entry, isSelected: index == selectionIndex)
                                .id(entry.id)
                                .onTapGesture { onOpen(entry) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: min(
                    Self.listMaximumHeight,
                    CGFloat(results.count) * Self.estimatedRowHeight + 16
                ))
                // Keyboard selection can move the highlighted row past the visible fold; follow
                // it so the selection (and what Return will open) is always on screen.
                .onChange(of: selectionIndex) { _, newIndex in
                    guard results.indices.contains(newIndex) else { return }
                    proxy.scrollTo(results[newIndex].id)
                }
            }
        }
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private func resultRow(_ entry: QuickOpenEntry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(entry.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.directoryDisplayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // The sidebar's selected-file look: soft translucent accent tint + accent text.
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(OutlineSidebarView.rowSelectionFillOpacity))
                : nil
        )
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(entry.directoryDisplayPath)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func moveSelection(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectionIndex = min(max(selectionIndex + delta, 0), count - 1)
    }

    private func openSelection() {
        let results = results
        guard results.indices.contains(selectionIndex) else { return }
        onOpen(results[selectionIndex])
    }
}
