import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var sourceFolder: URL?
    @State private var result: ScanResult?
    @State private var isScanning = false
    @State private var isPreparingLightroom = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isDropTargeted = false
    @State private var bracketMode: BracketMode = .automatic
    @State private var currentProgress = "Připraveno"
    @State private var debugLines: [String] = ["Připraveno."]

    private let scanner = PhotoScanner()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Reality Processor")
        .alert("Chyba", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Neznámá chyba")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REALITY PROCESSOR")
                    .font(.title2.bold())
                Text("HDR workflow · v0.16")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Zdrojová složka") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sourceFolder?.path(percentEncoded: false) ?? "Není vybraná složka")
                        .font(.caption)
                        .foregroundStyle(sourceFolder == nil ? .secondary : .primary)
                        .lineLimit(3)

                    Button("Vybrat složku…", action: chooseFolder)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Bracketing") {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("Režim", selection: $bracketMode) {
                        ForEach(BracketMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(bracketMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Max. rozestup série: 12 s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Button(action: analyze) {
                HStack {
                    if isScanning { ProgressView().controlSize(.small) }
                    Text(isScanning ? "Analyzuji…" : "Analyzovat")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sourceFolder == nil || isScanning || isPreparingLightroom)

            Button(action: prepareLightroom) {
                HStack {
                    if isPreparingLightroom { ProgressView().controlSize(.small) }
                    Label(
                        isPreparingLightroom ? "Zpracovávám HDR…" : "Připravit Lightroom HDR",
                        systemImage: "wand.and.rays"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(result?.brackets.isEmpty != false || isPreparingLightroom)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressPanel

            Spacer(minLength: 4)

            Text("v0.16: kolekce podle data/času + automatické HDR merge + live debug.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private var progressPanel: some View {
        GroupBox("Průběh / debug") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if isScanning || isPreparingLightroom {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    }

                    Text(currentProgress)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(debugLines.suffix(10).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 125)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let result {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    StatCard(title: "Fotky", value: "\(result.allPhotos.count)", icon: "photo.on.rectangle")
                    StatCard(title: "HDR série", value: "\(result.brackets.count)", icon: "square.stack.3d.up")
                    StatCard(title: "Mimo série", value: "\(result.ungrouped.count)", icon: "exclamationmark.triangle")
                }

                Text("Nalezené HDR série")
                    .font(.headline)

                if result.brackets.isEmpty {
                    ContentUnavailableView(
                        "Žádná jistá HDR série",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("Pokud RAW metadata neobsahují EV bias, upravíme detekci podle konkrétního foťáku.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(result.brackets, id: \.id) { group in
                                BracketRow(group: group)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(22)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                Text("Přetáhni sem složku s RAWy")
                    .font(.title2.bold())
                Text("nebo ji vyber vlevo")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .dropDestination(for: URL.self) { items, _ in
                guard let folder = items.first else { return false }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
                sourceFolder = folder
                result = nil
                statusMessage = nil
                currentProgress = "Složka vybrána"
                appendDebug("Vybrána složka: \(folder.lastPathComponent)")
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Vybrat"

        if panel.runModal() == .OK {
            sourceFolder = panel.url
            result = nil
            statusMessage = nil
            if let url = panel.url {
                currentProgress = "Složka vybrána"
                appendDebug("Vybrána složka: \(url.lastPathComponent)")
            }
        }
    }

    private func analyze() {
        guard let sourceFolder else { return }

        isScanning = true
        errorMessage = nil
        statusMessage = nil
        currentProgress = "Načítám metadata a hledám HDR série…"
        appendDebug("START analýzy · režim \(bracketMode.rawValue)")

        Task {
            do {
                let scan = try await scanner.scan(folder: sourceFolder, mode: bracketMode)
                await MainActor.run {
                    result = scan
                    isScanning = false
                    currentProgress = "Analýza dokončena"
                    appendDebug("DONE analýza · \(scan.allPhotos.count) fotek · \(scan.brackets.count) HDR · \(scan.ungrouped.count) mimo")
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isScanning = false
                    currentProgress = "Analýza selhala"
                    appendDebug("ERROR analýza · \(error.localizedDescription)")
                }
            }
        }
    }

    private func prepareLightroom() {
        guard let result, !result.brackets.isEmpty else { return }

        do {
            try LightroomBridge.clearAck()
            _ = try LightroomBridge.writeManifest(for: result)
            isPreparingLightroom = true
            errorMessage = nil
            currentProgress = "HDR fronta připravena"
            statusMessage = "Importuji, vytvářím kolekci a skládám HDR série…"
            appendDebug("START Lightroom · \(result.brackets.count) HDR sérií")

            LightroomBridge.openAndWaitForPlugin(
                progress: { rawState in
                    DispatchQueue.main.async {
                        currentProgress = LightroomBridge.readableState(rawState)
                        appendDebug("LR · \(rawState)")
                    }
                },
                completion: { outcome in
                    DispatchQueue.main.async {
                        isPreparingLightroom = false
                        switch outcome {
                        case .success(let detail):
                            statusMessage = detail
                            currentProgress = "HDR zpracování dokončeno"
                            appendDebug("DONE Lightroom · \(detail)")
                        case .failure(let message):
                            errorMessage = message
                            statusMessage = "Lightroom workflow nedokončil."
                            currentProgress = "Lightroom operaci nedokončil"
                            appendDebug("ERROR Lightroom · \(message)")
                        }
                    }
                }
            )
        } catch {
            errorMessage = error.localizedDescription
            currentProgress = "Příprava Lightroomu selhala"
            appendDebug("ERROR příprava · \(error.localizedDescription)")
        }
    }

    private func appendDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        debugLines.append("[\(formatter.string(from: Date()))] \(message)")
        if debugLines.count > 120 {
            debugLines.removeFirst(debugLines.count - 120)
        }
    }
}

private enum LightroomLaunchResult {
    case success(String)
    case failure(String)
}

private enum LightroomBridge {
    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RealityProcessor", isDirectory: true)
    }

    private static var ackURL: URL {
        supportFolder.appendingPathComponent("pending_hdr.ack")
    }

    private static var heartbeatURL: URL {
        supportFolder.appendingPathComponent("lightroom_bridge.heartbeat")
    }

    static func clearAck() throws {
        try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: ackURL.path) {
            try FileManager.default.removeItem(at: ackURL)
        }
    }

    static func writeManifest(for result: ScanResult) throws -> URL {
        try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)

        let manifestURL = supportFolder.appendingPathComponent("pending_hdr.lua")
        let triggerURL = supportFolder.appendingPathComponent("pending_hdr.trigger")

        func luaString(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        let groupBlocks = result.brackets.enumerated().map { index, group in
            let paths = group.photos
                .map { luaString($0.url.path(percentEncoded: false)) }
                .joined(separator: ",\n            ")

            return """
        {
            index = \(index + 1),
            preset = \(luaString(group.presetName)),
            paths = {
                \(paths)
            }
        }
"""
        }.joined(separator: ",\n")

        let lua = """
return {
    version = 4,
    createdAt = \(luaString(ISO8601DateFormatter().string(from: Date()))),
    groups = {
\(groupBlocks)
    }
}
"""

        try lua.write(to: manifestURL, atomically: true, encoding: .utf8)
        try ISO8601DateFormatter().string(from: Date()).write(to: triggerURL, atomically: true, encoding: .utf8)
        return manifestURL
    }

    static func openAndWaitForPlugin(
        progress: @escaping (String) -> Void,
        completion: @escaping (LightroomLaunchResult) -> Void
    ) {
        guard openLightroomClassic() else {
            completion(.failure("Adobe Lightroom Classic nebyl nalezen v Applications."))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // HDR merge může u větší zakázky trvat několik minut.
            let deadline = Date().addingTimeInterval(30 * 60)
            var lastHeartbeat: String?

            while Date() < deadline {
                if let ack = try? String(contentsOf: ackURL, encoding: .utf8) {
                    let text = ack.trimmingCharacters(in: .whitespacesAndNewlines)

                    if text.hasPrefix("OK|") {
                        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
                        let groups = parts.count > 1 ? String(parts[1]) : "?"
                        let raws = parts.count > 2 ? String(parts[2]) : "?"
                        let merged = parts.count > 3 ? String(parts[3]) : "?"
                        let collection = parts.count > 4 ? String(parts[4]) : "?"
                        completion(.success("Hotovo: \(merged)/\(groups) HDR · \(raws) RAWů · kolekce \(collection)"))
                        return
                    }

                    if text.hasPrefix("ERROR:") {
                        completion(.failure("Lightroom plugin vrátil chybu: \(text)"))
                        return
                    }
                }

                if let heartbeat = try? String(contentsOf: heartbeatURL, encoding: .utf8) {
                    let text = heartbeat.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, text != lastHeartbeat {
                        lastHeartbeat = text
                        progress(text)
                    }
                }

                Thread.sleep(forTimeInterval: 0.25)
            }

            let heartbeat = (try? String(contentsOf: heartbeatURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            completion(.failure("Lightroom workflow se do 30 minut nedokončil. Poslední stav: \(heartbeat ?? "bez heartbeat")"))
        }
    }

    static func readableState(_ raw: String) -> String {
        switch raw {
        case "started": return "Lightroom bridge spuštěn"
        case "alive": return "Lightroom bridge čeká na frontu"
        case "loading-manifest": return "Načítám HDR frontu"
        case "scanning-catalog": return "Kontroluji Lightroom katalog"
        case "waiting-for-catalog-write": return "Čekám na uvolnění katalogu"
        case "import-complete": return "Import RAWů dokončen"
        case "rebuilding-groups": return "Sestavuji HDR skupiny"
        case "writing-ack": return "Dokončuji workflow"
        case "processed": return "Lightroom workflow dokončen"
        case "selecting-collection": return "Dokončuji výběr v Lightroomu"
        default:
            if raw.hasPrefix("importing:") {
                return "Importuji RAWy \(raw.replacingOccurrences(of: "importing:", with: ""))"
            }
            if raw.hasPrefix("groups-ready:") {
                return "HDR skupiny připravené (\(raw.replacingOccurrences(of: "groups-ready:", with: "")) RAWů)"
            }
            if raw.hasPrefix("creating-collection:") {
                return "Vytvářím kolekci"
            }
            if raw.hasPrefix("adding-to-collection:") {
                return "Přidávám fotky do kolekce"
            }
            if raw.hasPrefix("collection-ready:") {
                return "Kolekce vytvořena"
            }
            if raw.hasPrefix("hdr-selecting:") {
                return "Připravuji HDR sérii \(raw.replacingOccurrences(of: "hdr-selecting:", with: ""))"
            }
            if raw.hasPrefix("hdr-triggering:") {
                return "Spouštím HDR merge \(raw.replacingOccurrences(of: "hdr-triggering:", with: ""))"
            }
            if raw.hasPrefix("hdr-merging:") {
                return "Lightroom skládá HDR \(raw.replacingOccurrences(of: "hdr-merging:", with: ""))"
            }
            if raw.hasPrefix("hdr-created:") {
                return "HDR vytvořeno \(raw.replacingOccurrences(of: "hdr-created:", with: ""))"
            }
            if raw.hasPrefix("hdr-timeout:") || raw.hasPrefix("hdr-trigger-error:") || raw.hasPrefix("processor-error:") {
                return "Chyba při HDR zpracování"
            }
            return "Lightroom: \(raw)"
        }
    }

    @discardableResult
    static func openLightroomClassic() -> Bool {
        let workspace = NSWorkspace.shared
        let candidates = [
            "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom Classic.app"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            workspace.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return true
        }

        if let appURL = workspace.urlForApplication(withBundleIdentifier: "com.adobe.LightroomClassicCC7") {
            workspace.openApplication(at: appURL, configuration: .init())
            return true
        }

        return false
    }
}

private struct BracketRow: View {
    let group: BracketGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(group.title)
                        .fontWeight(.medium)
                    Text(group.presetName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(group.evSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(group.confidence * 100)) %")
                    .fontWeight(.semibold)
                Text(group.confidence >= 0.90 ? "Jistá série" : "Zkontrolovat")
                    .font(.caption)
                    .foregroundStyle(group.confidence >= 0.90 ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
