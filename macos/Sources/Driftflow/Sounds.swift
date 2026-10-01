import AVFoundation

enum SoundStyle: String, CaseIterable, Identifiable {
    case classic, bells, glass, minimal, pop

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bells: "Soft Bells"
        case .glass: "Glass"
        case .minimal: "Minimal"
        case .classic: "Classic"
        case .pop: "Pop"
        }
    }

    var detail: String {
        switch self {
        case .bells: "Two gentle notes rise to open and fall to close"
        case .glass: "A single crystal tone with a soft shimmer"
        case .minimal: "The quietest: a short, low pulse"
        case .classic: "The original macOS Tink and Pop"
        case .pop: "A bubble pops to open, two soft pops to close"
        }
    }
}

/// Driftflow's feedback sounds (synthesized by Resources/Sounds/make_sounds.swift), preloaded so
/// they play with no disk or decode delay.
@MainActor
final class Sounds {
    /// File-name prefix for a style's start/stop files.
    private static func prefix(_ style: SoundStyle) -> String { style.rawValue }

    enum Cue {
        case start
        case stop
        case cancel
    }

    private var players: [String: AVAudioPlayer] = [:]
    private var previewWork: DispatchWorkItem?

    func play(_ cue: Cue, style: SoundStyle) {
        let name = switch cue {
        case .start: "\(Self.prefix(style))-start"
        case .stop: "\(Self.prefix(style))-stop"
        case .cancel: "cancel"
        }
        guard let player = player(named: name) else { return }
        player.currentTime = 0
        player.play()
    }

    /// Plays a style's start sound, then its stop sound, the way a dictation would.
    func preview(_ style: SoundStyle) {
        previewWork?.cancel()
        play(.start, style: style)
        let work = DispatchWorkItem { [weak self] in self?.play(.stop, style: style) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Loads (and keeps) the players for a style ahead of use.
    func preload(_ style: SoundStyle) {
        _ = player(named: "\(Self.prefix(style))-start")
        _ = player(named: "\(Self.prefix(style))-stop")
        _ = player(named: "cancel")
    }

    /// The Classic set uses the built-in macOS sounds, at the quiet level Driftflow first shipped with.
    private static let systemSounds = [
        "classic-start": "/System/Library/Sounds/Tink.aiff",
        "classic-stop": "/System/Library/Sounds/Pop.aiff",
    ]

    /// Every set plays at the same gentle loudness: the file's RMS is measured once and the player
    /// volume scaled to hit Soft Bells' level (RMS 0.076 at volume 0.8).
    private static func volume(toMatchLoudnessOf url: URL) -> Float {
        let target: Float = 0.076 * 0.8
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return 0.5 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, target / max(rms, 0.001))
    }

    private func player(named name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let url = Self.systemSounds[name].map { URL(fileURLWithPath: $0) }
            ?? ["caf", "wav", "m4a"].lazy.compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = Self.volume(toMatchLoudnessOf: url)
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
