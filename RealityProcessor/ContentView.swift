import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var sourceFolder: URL?
    @State private var result: ScanResult?
    @State private var isScanning = false
    @State private var errorMessage: String?
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
                Text("HDR workflow · v0.6")
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
            .disabled(sourceFolder == nil || isScanning)

            Spacer()

            Text("Teď řešíme pouze ingest + detekci HDR sérií. Lightroom přijde jako další modul.")
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
        }
    }

    private func analyze() {
        guard let sourceFolder else { return }
        isScanning = true
        errorMessage = nil
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
