import Foundation

/// One slice of a mermaid `pie` chart. `value` is always > 0 (parser rejects otherwise).
struct MermaidPieSlice: Equatable {
    let label: String
    let value: Double
}

/// Parsed mermaid `pie` chart. Always has >= 1 slice and a positive total.
struct MermaidPieModel: Equatable {
    let title: String?
    let slices: [MermaidPieSlice]

    var total: Double { slices.reduce(0) { $0 + $1.value } }

    /// This slice's share of the whole (0...1).
    func fraction(of slice: MermaidPieSlice) -> Double {
        total > 0 ? slice.value / total : 0
    }
}

/// Parses mermaid `pie` syntax into a drawable model. Pure; no rendering.
enum MermaidPieChart {
    /// Returns nil for anything unrenderable (not a pie, no slices, or any non-positive /
    /// non-numeric value) so the caller degrades to the clean captioned fallback.
    static func parse(_ source: String) -> MermaidPieModel? {
        var lines = MermaidSource.significantLines(source)
        guard let header = lines.first, header.lowercased().hasPrefix("pie") else { return nil }
        lines.removeFirst()

        let title = parseTitle(fromHeader: header)

        var slices: [MermaidPieSlice] = []
        for line in lines {
            guard let slice = parseSlice(line) else { return nil }  // any malformed data line → whole block fails
            slices.append(slice)
        }
        // A legend row per slice sizes the raster; hundreds of slices is both unreadable and a
        // large one-shot bitmap allocation (row height × scale). Bail to the captioned-source
        // fallback rather than draw a giant, useless chart.
        // `isFinite` and `maximumSliceValue` are load-bearing, not tidiness: the renderer converts
        // values to `Int` for the legend, and `Int(v)` TRAPS — a hard crash, uncatchable — for
        // `inf`, for `nan`'s percent arithmetic, and for any value above `Double(Int.max)`. Every
        // Double at or above 2^52 is its own `.rounded()`, so a 20-digit slice value always took
        // that branch. Same shape as the ordered-list `Int.max` crash: an unbounded number parsed
        // out of document text reaching an `Int` conversion. A rejected block degrades to the
        // captioned-source fallback, which is the documented behavior for unrenderable input.
        guard
            !slices.isEmpty,
            slices.count <= maxSlices,
            slices.allSatisfy({ $0.value > 0 && $0.value.isFinite && $0.value <= maximumSliceValue })
        else { return nil }
        return MermaidPieModel(title: title, slices: slices)
    }

    /// Upper bound on renderable slices (see `parse`). A real pie chart has a handful; this only
    /// rejects pathological input.
    static let maxSlices = 100

    /// Upper bound on a renderable slice value (see `parse`). Far above any real chart and far
    /// below `Double(Int.max)`, so the legend's `Int` conversions cannot trap.
    static let maximumSliceValue: Double = 1e15

    /// `pie [showData] [title <text>]` → the title text, or nil.
    private static func parseTitle(fromHeader header: String) -> String? {
        // Strip a leading "pie" and an optional "showData", then look for "title <rest>".
        var rest = header
        rest = String(rest.dropFirst(3))                                  // drop "pie"
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("showdata") {
            rest = String(rest.dropFirst("showdata".count)).trimmingCharacters(in: .whitespaces)
        }
        if rest.lowercased().hasPrefix("title") {
            let t = String(rest.dropFirst("title".count)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// `"label" : value` → a slice, or nil if the line isn't a valid data line.
    private static func parseSlice(_ line: String) -> MermaidPieSlice? {
        guard line.first == "\"" else { return nil }
        let afterOpen = line.dropFirst()
        guard let closeQuote = afterOpen.firstIndex(of: "\"") else { return nil }
        let label = String(afterOpen[afterOpen.startIndex..<closeQuote])
        var remainder = String(afterOpen[afterOpen.index(after: closeQuote)...])
            .trimmingCharacters(in: .whitespaces)
        guard remainder.first == ":" else { return nil }
        remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard let value = Double(remainder) else { return nil }
        return MermaidPieSlice(label: label, value: value)
    }

}
