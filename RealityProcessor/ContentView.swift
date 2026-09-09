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
                Text("HDR workflow · v0.9")
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
                        isPreparingLightroom ? "Spouštím Lightroom…" : "Připravit Lightroom HDR",
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

            Text("v0.9: otevírá Lightroom Classic a cíleně spouští Library → Plug-in Extras → Reality Processor.")
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
                            ForEach(result.brackets, id: \BracketGroup.id) { (group: BracketGroup) in
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
            let manifestURL = try LightroomBridge.writeManifest(for: result)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(manifestURL.path(percentEncoded: false), forType: .string)

            isPreparingLightroom = true
            errorMessage = nil
            statusMessage = "HDR fronta připravena: \(result.brackets.count) sérií. Spouštím Lightroom plugin…"

            LightroomBridge.openAndRunPlugin { outcome in
                DispatchQueue.main.async {
                    isPreparingLightroom = false
                    switch outcome {
                    case .success:
                        statusMessage = "Lightroom plugin spuštěn. Lightroom teď načítá RAWy a vybírá první HDR sérii."
                    case .failure(let message):
                        errorMessage = message
                        statusMessage = "Fronta je připravená, ale plugin se nepodařilo automaticky spustit."
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum LightroomLaunchResult {
    case success
    case failure(String)
}

private enum LightroomBridge {
    static func writeManifest(for result: ScanResult) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("RealityProcessor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let manifestURL = folder.appendingPathComponent("pending_hdr.lua")

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
    version = 1,
    createdAt = \(luaString(ISO8601DateFormatter().string(from: Date()))),
    groups = {
\(groupBlocks)
    }
}
"""

        try lua.write(to: manifestURL, atomically: true, encoding: .utf8)
        return manifestURL
    }

    static func openAndRunPlugin(completion: @escaping (LightroomLaunchResult) -> Void) {
        openLightroomClassic()

        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 3.0)

            let script = #"""
            tell application "Adobe Lightroom Classic" to activate
            delay 1

            tell application "System Events"
                set lrProcess to missing value
                repeat 30 times
                    try
                        set lrProcess to first application process whose name contains "Lightroom Classic"
                        exit repeat
                    end try
                    delay 0.5
                end repeat

                if lrProcess is missing value then
                    error "Proces Adobe Lightroom Classic nebyl nalezen."
                end if

                tell lrProcess
                    set targetName to "Reality Processor: Načíst HDR frontu"

                    -- Lightroom SDK LrLibraryMenuItems se zobrazuje v Library → Plug-in Extras.
                    try
                        click menu bar item "Library" of menu bar 1
                        delay 0.25
                        tell menu 1 of menu bar item "Library" of menu bar 1
                            if exists menu item "Plug-in Extras" then
                                tell menu item "Plug-in Extras"
                                    delay 0.2
                                    if exists menu 1 then
                                        tell menu 1
                                            if exists menu item targetName then
                                                click menu item targetName
                                                return "OK"
                                            end if
                                        end tell
                                    end if
                                end tell
                            end if
                        end tell
                    end try

                    -- Některé verze Lightroomu mohou Plug-in Extras ukázat pod File.
                    try
                        click menu bar item "File" of menu bar 1
                        delay 0.25
                        tell menu 1 of menu bar item "File" of menu bar 1
                            if exists menu item "Plug-in Extras" then
                                tell menu item "Plug-in Extras"
                                    delay 0.2
                                    if exists menu 1 then
                                        tell menu 1
                                            if exists menu item targetName then
                                                click menu item targetName
                                                return "OK"
                                            end if
                                        end tell
                                    end if
                                end tell
                            end if
                        end tell
                    end try

                    -- Poslední fallback: projdi hlavní menu a jejich první dvě úrovně.
                    repeat with topItem in menu bar items of menu bar 1
                        try
                            click topItem
                            delay 0.1
                            set topMenu to menu 1 of topItem
                            repeat with menuItemRef in menu items of topMenu
                                try
                                    if (name of menuItemRef as text) is targetName then
                                        click menuItemRef
                                        return "OK"
                                    end if
                                end try
                                try
                                    if exists menu 1 of menuItemRef then
                                        repeat with subItem in menu items of menu 1 of menuItemRef
                                            try
                                                if (name of subItem as text) is targetName then
                                                    click subItem
                                                    return "OK"
                                                end if
                                            end try
                                        end repeat
                                    end if
                                end try
                            end repeat
                        end try
                    end repeat
                end tell
            end tell

            error "Plugin je nainstalovaný, ale jeho menu položku se nepodařilo přes macOS UI najít. Zkus v Lightroomu ručně Library → Plug-in Extras a ověř, že tam je Reality Processor: Načíst HDR frontu."
            """#

            let process = Process()
            let output = Pipe()
            let errorOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = output
            process.standardError = errorOutput

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    completion(.success)
                } else {
                    let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
                    let detail = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = detail?.isEmpty == false ? detail! : "Automatizace Lightroomu selhala."
                    completion(.failure(
                        message + "\n\nPokud macOS zobrazí žádost o oprávnění, povol Reality Processor/osascript v Nastavení systému → Soukromí a zabezpečení → Zpřístupnění."
                    ))
                }
            } catch {
                completion(.failure("Nepodařilo se spustit macOS automatizaci: \(error.localizedDescription)"))
            }
        }
    }

    static func openLightroomClassic() {
        let workspace = NSWorkspace.shared
        let candidates = [
            "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom Classic.app"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            workspace.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return
        }

        if let appURL = workspace.urlForApplication(withBundleIdentifier: "com.adobe.LightroomClassicCC7") {
            workspace.openApplication(at: appURL, configuration: .init())
        }
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
