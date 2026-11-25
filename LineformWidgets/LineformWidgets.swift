import AppIntents
import SwiftUI
import WidgetKit

// Lineform's widgets (owner, 2026-11-24, §26): the Recent documents home-screen widget — plain
// stacked lines, title and date, thin green separators; a tap opens that document — and Control
// Center's "New Lineform Note". The widget only reads the list the app writes
// (`WidgetRecents`); it never reads documents.

@main
struct LineformWidgets: WidgetBundle {
    var body: some Widget {
        RecentDocumentsWidget()
        NewNoteControl()
    }
}

struct RecentDocumentsEntry: TimelineEntry {
    let date: Date
    let documents: [WidgetRecentDocument]
}

struct RecentDocumentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentDocumentsEntry {
        RecentDocumentsEntry(date: .now, documents: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentDocumentsEntry) -> Void) {
        let documents = WidgetRecents.load()
        completion(RecentDocumentsEntry(date: .now, documents: context.isPreview && documents.isEmpty ? Self.sample : documents))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentDocumentsEntry>) -> Void) {
        // The app reloads the widget whenever the list changes; the hourly refresh only keeps the
        // relative dates ("2 hr. ago") current.
        let entry = RecentDocumentsEntry(date: .now, documents: WidgetRecents.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60))))
    }

    static let sample: [WidgetRecentDocument] = [
        WidgetRecentDocument(title: String(localized: "Meeting notes"), path: "/sample/1", location: "iCloud", modified: .now.addingTimeInterval(-600)),
        WidgetRecentDocument(title: String(localized: "Draft"), path: "/sample/2", location: "iCloud", modified: .now.addingTimeInterval(-7200)),
        WidgetRecentDocument(title: String(localized: "Ideas"), path: "/sample/3", location: "iCloud", modified: .now.addingTimeInterval(-86_400)),
    ]
}

struct RecentDocumentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetRecents.widgetKind, provider: RecentDocumentsProvider()) { entry in
            RecentDocumentsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Recent Documents"))
        .description(String(localized: "Your newest Lineform documents. Tap one to open it."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentDocumentsView: View {
    let entry: RecentDocumentsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var count: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 3
        default: WidgetRecents.limit
        }
    }

    /// The app's status green (`EditorStatusGreen`), for the separators.
    private var green: Color {
        colorScheme == .dark
            ? Color(red: 0.40, green: 0.82, blue: 0.55)
            : Color(red: 0.08, green: 0.47, blue: 0.24)
    }

    var body: some View {
        let documents = Array(entry.documents.prefix(count))
        if documents.isEmpty {
            Text(String(localized: "No recent documents"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .widgetURL(WidgetRecents.newNoteURL)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(documents.enumerated()), id: \.element.path) { index, document in
                    if index > 0 {
                        Rectangle().fill(green.opacity(0.55)).frame(height: 0.5)
                    }
                    line(document)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The small widget can't hold separate links: a tap opens the newest document.
            .widgetURL(family == .systemSmall ? documents.first.map(WidgetRecents.openURL(for:)) : nil)
        }
    }

    @ViewBuilder
    private func line(_ document: WidgetRecentDocument) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: document.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let modified = document.modified {
                Text(Self.relative(modified, now: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, family == .systemSmall ? 5 : 6)
        if family == .systemSmall {
            content
        } else {
            Link(destination: WidgetRecents.openURL(for: document)) { content }
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LineformNewNoteControl") {
            ControlWidgetButton(action: NewLineformNoteControlIntent()) {
                Label(String(localized: "New Lineform Note"), systemImage: "square.and.pencil")
            }
        }
        .displayName(LocalizedStringResource("New Lineform Note"))
        .description(LocalizedStringResource("Opens a new note in Lineform."))
    }
}
