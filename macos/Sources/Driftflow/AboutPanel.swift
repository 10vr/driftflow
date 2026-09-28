import AppKit

/// Driftflow's About window: the standard macOS panel (icon, name, version) with a description,
/// links, the licence and the open-source work it builds on.
@MainActor
enum AboutPanel {
    static let website = URL(string: "https://github.com/10vr/driftflow")!
    static let releases = URL(string: "https://github.com/10vr/driftflow/releases")!
    static let reportProblem = URL(string: "https://github.com/10vr/driftflow/issues/new")!

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Driftflow. Free software under the GNU GPL v3.",
        ])
    }

    private static var credits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        let quiet = body.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }
        let heading = body.merging([.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]) { $1 }

        let text = NSMutableAttributedString()
        func add(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        func link(_ title: String, _ url: URL) {
            add(title, body.merging([.link: url]) { $1 })
        }

        add("Private, instant dictation. Hold a key, speak, let go: your words appear wherever you're typing.\n", body)
        add("Speech is transcribed on this Mac. Nothing you say leaves it.\n\n", quiet)
        link("Website", website)
        add("   ·   ", quiet)
        link("What's new", releases)
        add("   ·   ", quiet)
        link("Report a problem", reportProblem)
        add("\n\n", body)
        add("Built with\n", heading)
        add("NVIDIA Parakeet speech models · FluidAudio (Neural Engine) · Apple Speech and Apple Intelligence · Sparkle (updates)\n", quiet)
        return text
    }
}
