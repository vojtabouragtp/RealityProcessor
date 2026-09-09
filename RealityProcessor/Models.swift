import Foundation

enum BracketMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case camera5 = "Foťák · 5"
    case drone3 = "Dron · 3"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .automatic:
            return "DNG → −1 / 0 / +1 · ostatní RAW → −2 / −1 / 0 / +1 / +2"
        case .camera5:
            return "5 snímků · −2 / −1 / 0 / +1 / +2 EV"
        case .drone3:
            return "3 snímky · −1 / 0 / +1 EV"
        }
    }
}

struct PhotoFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let captureDate: Date?
    let exposureBias: Double?
    let exposureTime: Double?
    let fNumber: Double?
    let iso: Double?

    var filename: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isDNG: Bool { fileExtension == "dng" }

    // Vyšší hodnota = světlejší expozice. Rozdíl 1.0 odpovídá přibližně 1 EV.
    var exposureLevel: Double? {
        guard let exposureTime, exposureTime > 0 else { return nil }
        let isoValue = max(iso ?? 100, 1)
        let aperture = max(fNumber ?? 1, 0.1)
        return log2(exposureTime * isoValue / (aperture * aperture))
    }
}

struct BracketGroup: Identifiable, Hashable {
    let id = UUID()
    let photos: [PhotoFile]
    let confidence: Double
    let presetName: String

    var title: String {
        guard let first = photos.first else { return "Prázdná série" }
        return first.filename + " … " + (photos.last?.filename ?? "")
    }

    var evSummary: String {
        photos.map { photo in
            guard let ev = photo.exposureBias else { return "?" }
            return String(format: "%+.1f", ev)
        }.joined(separator: "  ")
    }
}

struct ScanResult {
    let allPhotos: [PhotoFile]
    let brackets: [BracketGroup]
    let ungrouped: [PhotoFile]
}
