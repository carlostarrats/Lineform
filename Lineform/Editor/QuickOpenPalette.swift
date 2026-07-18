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

    static let maximumCardWidth: CGFloat = 560
    static let listMaximumHeight: CGFloat = 320

    private var results: [QuickOpenEntry] {
        QuickOpenIndex.search(entries, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to file…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
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

            Divider()

            resultsList
        }
        .frame(width: min(Self.maximumCardWidth, max(280, availableWidth - 48)))
        // Same two fixed chrome variants as the Find & Replace card, at modal weight.
        .environment(\.colorScheme, usesDarkChrome ? .dark : .light)
        .background(
            RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius)
                .fill(
                    usesDarkChrome
                        ? Color(white: 0.15)
                        : Color(white: MuseModalChrome.backgroundWhiteComponent)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MuseModalChrome.cornerRadius)
                .strokeBorder(
                    usesDarkChrome ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
                )
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        resultRow(entry, isSelected: index == selectionIndex)
                            .onTapGesture { onOpen(entry) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: Self.listMaximumHeight)
        }
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func resultRow(_ entry: QuickOpenEntry, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.relativePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.22))
                : nil
        )
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(entry.relativePath)")
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
