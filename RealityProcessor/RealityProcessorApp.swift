import SwiftUI
import AppKit

@main
struct RealityProcessorApp: App {
    init() {
        if let symbol = NSImage(
            systemSymbolName: "camera.aperture",
            accessibilityDescription: "Reality Processor"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 320, weight: .semibold)
        ) {
            let icon = NSImage(size: NSSize(width: 512, height: 512))
            icon.lockFocus()

            let backgroundRect = NSRect(x: 20, y: 20, width: 472, height: 472)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: backgroundRect, xRadius: 105, yRadius: 105).fill()

            symbol.isTemplate = true
            NSColor.white.set()
            symbol.draw(in: NSRect(x: 96, y: 96, width: 320, height: 320))

            icon.unlockFocus()
            icon.isTemplate = false
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            HSplitView {
                ContentView()
                    .frame(minWidth: 900, minHeight: 620)

                HDRMergeSettingsView()
                    .frame(minWidth: 235, idealWidth: 255, maxWidth: 285, maxHeight: .infinity)
            }
            .frame(minWidth: 1140, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

private struct HDRMergeSettingsView: View {
    @AppStorage("hdr.autoAlign") private var autoAlign = true
    @AppStorage("hdr.autoSettings") private var autoSettings = false
    @AppStorage("hdr.deghost") private var deghost = "None"
    @AppStorage("hdr.showDeghostOverlay") private var showDeghostOverlay = false
    @AppStorage("hdr.createStack") private var createStack = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("HDR Merge", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Text("Nastavení se použije na všechny nalezené série.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Auto Align", isOn: $autoAlign)
            Toggle("Auto Settings", isOn: $autoSettings)

            VStack(alignment: .leading, spacing: 7) {
                Text("Deghost Amount")
                    .font(.subheadline.weight(.medium))

                Picker("Deghost Amount", selection: $deghost) {
                    Text("None").tag("None")
                    Text("Low").tag("Low")
                    Text("Medium").tag("Medium")
                    Text("High").tag("High")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Toggle("Show Deghost Overlay", isOn: $showDeghostOverlay)
            Toggle("Create Stack", isOn: $createStack)

            Divider()

            Text("Automatika otevře HDR dialog, nastaví tyto volby a sama stiskne Merge.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(18)
        .background(.background)
        .onAppear(perform: saveSettings)
        .onChange(of: autoAlign) { _, _ in saveSettings() }
        .onChange(of: autoSettings) { _, _ in saveSettings() }
        .onChange(of: deghost) { _, _ in saveSettings() }
        .onChange(of: showDeghostOverlay) { _, _ in saveSettings() }
        .onChange(of: createStack) { _, _ in saveSettings() }
    }

    private func saveSettings() {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RealityProcessor", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

            let text = """
return {
    autoAlign = \(autoAlign ? "true" : "false"),
    autoSettings = \(autoSettings ? "true" : "false"),
    deghost = "\(deghost)",
    showDeghostOverlay = \(showDeghostOverlay ? "true" : "false"),
    createStack = \(createStack ? "true" : "false")
}
"""
            try text.write(
                to: support.appendingPathComponent("hdr_settings.lua"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("RealityProcessor: failed to save HDR settings: %@", error.localizedDescription)
        }
    }
}
