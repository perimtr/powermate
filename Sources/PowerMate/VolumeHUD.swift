import AppKit

/// A small floating bezel showing the volume level while the knob turns -
/// the equivalent of the system's volume-key overlay, since changing volume
/// through CoreAudio doesn't trigger the native one.
final class VolumeHUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let barTrack = NSView()
    private let barFill = NSView()
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private static let size = NSSize(width: 240, height: 48)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        icon.frame = NSRect(x: 14, y: 12, width: 24, height: 24)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        effect.addSubview(icon)

        barTrack.frame = NSRect(x: 50, y: 21, width: 128, height: 6)
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 3
        barTrack.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        effect.addSubview(barTrack)

        barFill.frame = NSRect(x: 0, y: 0, width: 0, height: 6)
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.layer?.backgroundColor = NSColor.labelColor.cgColor
        barTrack.addSubview(barFill)

        label.frame = NSRect(x: 184, y: 14, width: 44, height: 20)
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        effect.addSubview(label)
    }

    func show(volume: Float, muted: Bool) {
        let symbolName: String
        if muted {
            symbolName = "speaker.slash.fill"
        } else if volume <= 0.01 {
            symbolName = "speaker.fill"
        } else if volume < 0.34 {
            symbolName = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        label.stringValue = muted ? "×" : "\(Int((volume * 100).rounded()))%"

        let width = muted ? 0 : CGFloat(volume) * barTrack.bounds.width
        barFill.frame = NSRect(x: 0, y: 0, width: width, height: barTrack.bounds.height)
        barFill.layer?.opacity = muted ? 0.4 : 1.0

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - Self.size.width / 2,
                y: frame.maxY - Self.size.height - 24))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
        }
    }
}
