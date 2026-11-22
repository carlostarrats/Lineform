import CoreGraphics
import Foundation

/// Paper sizes offered for PDF export / print. Sizes are in PostScript points (1/72"). Covers the
/// common US (Letter/Legal/Tabloid) and ISO (A3/A4/A5) sheets printers use. One table for both
/// apps: the Mac's export sheet and print setup, and the iPhone's exporter.
public enum ExportPaperSize: CaseIterable, Equatable, Hashable, Sendable {
    case usLetter
    case usLegal
    case tabloid
    case a4
    case a3
    case a5

    public var sizeInPoints: CGSize {
        switch self {
        case .usLetter:
            return CGSize(width: 612, height: 792)    // 8.5 × 11"
        case .usLegal:
            return CGSize(width: 612, height: 1008)   // 8.5 × 14"
        case .tabloid:
            return CGSize(width: 792, height: 1224)   // 11 × 17"
        case .a4:
            return CGSize(width: 595, height: 842)     // 210 × 297 mm
        case .a3:
            return CGSize(width: 842, height: 1191)    // 297 × 420 mm
        case .a5:
            return CGSize(width: 420, height: 595)     // 148 × 210 mm
        }
    }

    public var displayName: String {
        switch self {
        case .usLetter:
            return String(localized: "US Letter", bundle: .module)
        case .usLegal:
            return String(localized: "US Legal", bundle: .module)
        case .tabloid:
            return String(localized: "Tabloid", bundle: .module)
        case .a4:
            return String(localized: "A4", bundle: .module)
        case .a3:
            return String(localized: "A3", bundle: .module)
        case .a5:
            return String(localized: "A5", bundle: .module)
        }
    }

    /// Content rect size = paper minus `preset`'s margins on all sides. This is the prose wrap
    /// width and the diagram/math image cap width.
    public func contentSize(preset: ExportTypographyPreset) -> CGSize {
        let paper = sizeInPoints
        let insets = preset.pageMargins
        return CGSize(
            width: paper.width - insets.left - insets.right,
            height: paper.height - insets.top - insets.bottom
        )
    }

    /// The offered sheet nearest `size`, compared in portrait (so a landscape page setup still
    /// finds its sheet). Ties go to the earlier case. The Mac calls this with
    /// `NSPrintInfo.shared.paperSize`.
    public static func closest(toPortrait size: CGSize) -> ExportPaperSize {
        let width = min(size.width, size.height)
        let height = max(size.width, size.height)
        return allCases.min(by: { a, b in
            let sa = a.sizeInPoints, sb = b.sizeInPoints
            let da = abs(sa.width - width) + abs(sa.height - height)
            let db = abs(sb.width - width) + abs(sb.height - height)
            return da < db
        }) ?? .usLetter
    }

    /// Regions whose everyday paper is US Letter.
    private static let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "PR"]

    /// The paper a person in `regionCode` most likely uses: US Letter in the Letter regions, A4
    /// everywhere else and when the region is unknown. Used by the iPhone, which has no print setup.
    public static func regionalDefault(regionCode: String?) -> ExportPaperSize {
        guard let regionCode, letterRegions.contains(regionCode.uppercased()) else { return .a4 }
        return .usLetter
    }
}
