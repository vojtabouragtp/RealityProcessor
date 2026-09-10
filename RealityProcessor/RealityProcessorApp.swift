import SwiftUI
import AppKit

@main
struct RealityProcessorApp: App {
    init() {
        // Rozpoznatelná ikona v Docku / Cmd-Tab i během vývoje bez binárního AppIcon assetu.
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
            let symbolRect = NSRect(x: 96, y: 96, width: 320, height: 320)
            symbol.draw(in: symbolRect)

            icon.unlockFocus()
            icon.isTemplate = false
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}
