import SwiftUI

enum Platform {
    /// Apple's SpeechAnalyzer models (macOS 26). Without them (macOS 15), Parakeet writes both the
    /// live preview and the final text, so only Parakeet's languages are offered.
    static let hasAppleSpeech: Bool = {
        guard #available(macOS 26.0, *) else { return false }
        return !SpeechEngine.disabledForTesting
    }()

    /// Languages available without Apple's models: Parakeet's (English, plus 24 more with TDT v3).
    static var parakeetLanguages: [String] { AccuracyModel.v3Languages.sorted() }
}

/// Liquid Glass on macOS 26; the closest earlier look on macOS 15 (frosted material, bordered buttons).
extension View {
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background {
                shape.fill(.regularMaterial)
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}
