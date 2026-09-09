import Foundation
import ImageIO

final class PhotoScanner {
    private let supportedExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng",
        "jpg", "jpeg", "tif", "tiff", "heic"
    ]

    private let cameraEVs: [Double] = [-2, -1, 0, 1, 2]
    private let droneEVs: [Double] = [-1, 0, 1]
    private let evTolerance = 0.35
    private let maxGroupSpan: TimeInterval = 12.0

    func scan(folder: URL, mode: BracketMode) async throws -> ScanResult {
        let urls = try discoverFiles(in: folder)
        let photos = urls.map(readMetadata)
            .sorted(by: sortPhotos)

        return detectBrackets(in: photos, mode: mode)
    }

    private func discoverFiles(in folder: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScannerError.cannotReadFolder
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if (try? url.resourceValues(forKeys: keys).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    private func readMetadata(_ url: URL) -> PhotoFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoFile(
                url: url,
                captureDate: filenameDate(url) ?? fileDate(url),
                exposureBias: nil,
                exposureTime: nil,
                fNumber: nil,
                iso: nil
            )
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let exposureBias = number(exif?[kCGImagePropertyExifExposureBiasValue])
        let exposureTime = number(exif?[kCGImagePropertyExifExposureTime])
        let fNumber = number(exif?[kCGImagePropertyExifFNumber])
        let iso = isoNumber(exif?[kCGImagePropertyExifISOSpeedRatings])
            ?? number(exif?[kCGImagePropertyExifPhotographicSensitivity])

        let captureDate = parseExifDate(exif?[kCGImagePropertyExifDateTimeOriginal])
            ?? parseExifDate(tiff?[kCGImagePropertyTIFFDateTime])
            ?? filenameDate(url)
            ?? fileDate(url)

        return PhotoFile(
            url: url,
            captureDate: captureDate,
            exposureBias: exposureBias,
            exposureTime: exposureTime,
            fNumber: fNumber,
            iso: iso
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }


    private func isoNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let numbers = value as? [NSNumber], let first = numbers.first { return first.doubleValue }
        if let values = value as? [Any], let first = values.first { return number(first) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    // DJI typicky používá např. DJI_20260909115803_0089_D.DNG.
    // Tohle je spolehlivější než datum souboru po zkopírování z karty.
    private func filenameDate(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: #"DJI_(\d{14})_"#) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let swiftRange = Range(match.range(at: 1), in: name) else { return nil }
        let stamp = String(name[swiftRange])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: stamp)
    }

    private func parseExifDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }

    private func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func sortPhotos(_ lhs: PhotoFile, _ rhs: PhotoFile) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (l?, r?) where l != r:
            return l < r
        default:
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    private func detectBrackets(in photos: [PhotoFile], mode: BracketMode) -> ScanResult {
        var groups: [BracketGroup] = []
        var used = Set<UUID>()
        var index = 0

        while index < photos.count {
            let preset = presetFor(photo: photos[index], mode: mode)
            let count = preset.targetEVs.count

            guard index + count <= photos.count else { break }
            let candidate = Array(photos[index..<(index + count)])

            // V Auto režimu nemícháme DNG a ostatní RAWy v jedné sérii.
            if mode == .automatic {
                let allDNG = candidate.allSatisfy(\.isDNG)
                let allNonDNG = candidate.allSatisfy { !$0.isDNG }
                if !allDNG && !allNonDNG {
                    index += 1
                    continue
                }
            }

            let score = bracketScore(candidate, targetEVs: preset.targetEVs)
            if score >= 0.78 {
                groups.append(BracketGroup(
                    photos: candidate,
                    confidence: score,
                    presetName: preset.name
                ))
                candidate.forEach { used.insert($0.id) }
                index += count
            } else {
                index += 1
            }
        }

        let ungrouped = photos.filter { !used.contains($0.id) }
        return ScanResult(allPhotos: photos, brackets: groups, ungrouped: ungrouped)
    }

    private func presetFor(photo: PhotoFile, mode: BracketMode) -> (name: String, targetEVs: [Double]) {
        switch mode {
        case .automatic:
            if photo.isDNG {
                return ("Dron · 3", droneEVs)
            } else {
                return ("Foťák · 5", cameraEVs)
            }
        case .camera5:
            return ("Foťák · 5", cameraEVs)
        case .drone3:
            return ("Dron · 3", droneEVs)
        }
    }

    private func bracketScore(_ photos: [PhotoFile], targetEVs: [Double]) -> Double {
        guard photos.count == targetEVs.count else { return 0 }

        var timeScore = 0.55
        if let first = photos.first?.captureDate,
           let last = photos.last?.captureDate {
            let span = last.timeIntervalSince(first)
            guard span >= 0, span <= maxGroupSpan else { return 0 }
            timeScore = max(0.55, 1.0 - span / (maxGroupSpan * 1.6))
        }

        // 1) Nejprve zkus standardní EXIF ExposureBiasValue.
        let biases = photos.compactMap(\.exposureBias)
        if biases.count == targetEVs.count {
            let normalized = normalizeEVs(biases)
            if let evScore = compareEVs(normalized, targetEVs: targetEVs) {
                return 0.30 * timeScore + 0.70 * evScore
            }
        }

        // 2) DJI DNG často EV bias neposkytne korektně. Relativní EV proto
        // dopočítáme z času závěrky, ISO a clony.
        let exposureLevels = photos.compactMap(\.exposureLevel)
        if exposureLevels.count == targetEVs.count {
            let normalized = normalizeEVs(exposureLevels)
            if let evScore = compareEVs(normalized, targetEVs: targetEVs) {
                return 0.30 * timeScore + 0.70 * evScore
            }
        }

        // 3) Fallback pro DJI AEB: když jde o tři DNG za sebou ve velmi krátkém
        // čase, přijmeme je jako bracket i při chybějících expozičních metadatech.
        if targetEVs.count == 3,
           photos.allSatisfy(\.isDNG),
           areSequentialDJIFiles(photos) {
            return max(0.82, timeScore * 0.90)
        }

        return 0
    }

    private func normalizeEVs(_ values: [Double]) -> [Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [] }
        let middle = sorted[sorted.count / 2]
        return sorted.map { $0 - middle }
    }

    private func compareEVs(_ values: [Double], targetEVs: [Double]) -> Double? {
        guard values.count == targetEVs.count else { return nil }
        let deviations = zip(values, targetEVs).map { abs($0 - $1) }
        // DJI může být lehce mimo přesných ±1 EV, proto je tolerance širší.
        let tolerance = targetEVs.count == 3 ? 0.55 : evTolerance
        guard deviations.allSatisfy({ $0 <= tolerance }) else { return nil }
        return max(0, 1.0 - (deviations.reduce(0, +) / Double(deviations.count)) / tolerance)
    }

    private func areSequentialDJIFiles(_ photos: [PhotoFile]) -> Bool {
        let numbers = photos.compactMap { djiSequenceNumber($0.filename) }
        guard numbers.count == photos.count else { return true }
        return zip(numbers, numbers.dropFirst()).allSatisfy { nextPair in
            nextPair.1 == nextPair.0 + 1
        }
    }

    private func djiSequenceNumber(_ filename: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"_(\d{4,})_[A-Za-z]\.DNG$"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let swiftRange = Range(match.range(at: 1), in: filename) else { return nil }
        return Int(filename[swiftRange])
    }

}

enum ScannerError: LocalizedError {
    case cannotReadFolder

    var errorDescription: String? {
        switch self {
        case .cannotReadFolder:
            return "Složku se nepodařilo načíst."
        }
    }
}
