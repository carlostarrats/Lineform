import Foundation

/// Reads an AI reply. The reply is untrusted: anything unexpected is refused (nil), never
/// repaired, and nothing here can trap on junk input.
enum AIResponseParser {
    /// The revised segments, or nil unless the reply's JSON object carries `segments` as an
    /// array of exactly `expectedCount` strings. Tolerates code fences and preambles by reading
    /// from the first `{` to the last `}`.
    static func segments(from reply: String, expectedCount: Int) -> [String]? {
        guard let object = jsonObject(in: reply),
              let array = object["segments"] as? [Any],
              array.count == expectedCount else { return nil }
        var result: [String] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let string = element as? String else { return nil }
            result.append(string)
        }
        return result
    }

    /// 0-based indices of the marked sentences: deduped, sorted, in range, and capped at
    /// `max(1, ⌈sentenceCount / 3⌉)` (the first ones kept). The model numbers from 1. nil when
    /// the reply has no `sentences` array.
    static func sentenceIndices(from reply: String, sentenceCount: Int) -> [Int]? {
        guard let object = jsonObject(in: reply),
              let array = object["sentences"] as? [Any] else { return nil }
        guard sentenceCount > 0 else { return [] }
        var seen = Set<Int>()
        for element in array {
            guard let number = element as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            // Bound before any Int conversion: a huge or non-finite number would trap.
            guard value.isFinite, value >= 1, value <= Double(sentenceCount), value == value.rounded() else { continue }
            seen.insert(Int(value) - 1)
        }
        let cap = max(1, (sentenceCount + 2) / 3)
        return Array(seen.sorted().prefix(cap))
    }

    private static func jsonObject(in reply: String) -> [String: Any]? {
        guard let open = reply.firstIndex(of: "{"),
              let close = reply.lastIndex(of: "}"),
              open < close else { return nil }
        let data = Data(reply[open...close].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
