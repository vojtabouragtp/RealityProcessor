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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REALITY PROCESSOR")
                    .font(.title2.bold())
                Text("HDR workflow · v0.14")
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
                        isPreparingLightroom ? "Čekám na Lightroom…" : "Připravit Lightroom HDR",
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

            Spacer()

            Text("v0.14: delší čekání na import a diagnostika přesného stavu Lightroom bridge.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 290)
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
                            ForEach(result.brackets, id: \BracketGroup.id) { group in
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
        }
    }

    private func analyze() {
        guard let sourceFolder else { return }
        isScanning = true
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let scan = try await scanner.scan(folder: sourceFolder, mode: bracketMode)
                await MainActor.run {
                    result = scan
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isScanning = false
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
            statusMessage = "HDR fronta připravena. Čekám, až ji Lightroom plugin převezme…"

            LightroomBridge.openAndWaitForPlugin { outcome in
                DispatchQueue.main.async {
                    isPreparingLightroom = false
                    switch outcome {
                    case .success(let detail):
                        statusMessage = detail
                    case .failure(let message):
                        errorMessage = message
                        statusMessage = "Lightroom frontu nedokončil."
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
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
    version = 3,
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

    static func openAndWaitForPlugin(completion: @escaping (LightroomLaunchResult) -> Void) {
        guard openLightroomClassic() else {
            completion(.failure("Adobe Lightroom Classic nebyl nalezen v Applications."))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(60)

            while Date() < deadline {
                if let ack = try? String(contentsOf: ackURL, encoding: .utf8) {
                    let text = ack.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("OK|") {
                        let parts = text.split(separator: "|")
                        let groups = parts.count > 1 ? String(parts[1]) : "?"
                        let raws = parts.count > 2 ? String(parts[2]) : "?"
                        completion(.success("Lightroom převzal frontu: \(groups) HDR sérií / \(raws) RAWů. První série je vybraná."))
                        return
                    }
                    if text.hasPrefix("ERROR:") {
                        completion(.failure("Lightroom plugin vrátil chybu: \(text)"))
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            let heartbeat = (try? String(contentsOf: heartbeatURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let heartbeat, !heartbeat.isEmpty {
                completion(.failure("Lightroom po 60 s operaci nedokončil. Poslední stav bridge: \(heartbeat). Pošli mi přesně tento stav."))
            } else {
                completion(.failure("Lightroom bridge se vůbec nespustil. Zkontroluj Reality Processor v Plug-in Manageru a dej Disable → Enable, případně Remove → Add."))
            }
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
