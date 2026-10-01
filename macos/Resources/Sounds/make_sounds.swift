// Synthesizes Driftflow's own feedback sound sets (Classic uses macOS sounds). Each set is a start/stop pair (plus one shared,
// barely-there cancel tap). All are quiet, rounded and short: calm, not clicky.
// Usage: swift make_sounds.swift <output dir>
import AVFoundation

let rate = 48_000.0
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: Building blocks

/// A tonal note: fundamental plus optional partials (ratio, gain, decay scale), two voices detuned
/// ±1.2 cents for warmth, raised-cosine attack, exponential decay.
struct Note {
    var frequency: Double
    var start: Double = 0
    var gain: Double = 1
    var decay: Double = 0.15
    var attack: Double = 0.012
    var partials: [(Double, Double, Double)] = [(1, 1, 1), (2, 0.18, 0.55), (3, 0.05, 0.35)]
    /// Pitch glide: frequency multiplies from 1 to `glideTo` over `glideTime` (bubble/droplet).
    var glideTo: Double = 1
    var glideTime: Double = 0.06
}

func addNote(_ note: Note, into samples: inout [Double]) {
    let first = Int(note.start * rate)
    var phase = [Double](repeating: 0, count: note.partials.count * 2)
    for i in first..<samples.count {
        let t = Double(i - first) / rate
        let attack = t < note.attack ? 0.5 - 0.5 * cos(.pi * t / note.attack) : 1
        let glide = 1 + (note.glideTo - 1) * min(1, t / note.glideTime) * (2 - min(1, t / note.glideTime))
        var value = 0.0
        for (k, partial) in note.partials.enumerated() {
            let envelope = exp(-t / (note.decay * partial.2))
            for (v, detune) in [1.0007, 0.9993].enumerated() {
                phase[k * 2 + v] += 2 * .pi * note.frequency * partial.0 * glide * detune / rate
                value += partial.1 * envelope * 0.5 * sin(phase[k * 2 + v])
            }
        }
        samples[i] += note.gain * attack * value
    }
}

func finish(_ raw: [Double], peak: Double) -> [Float] {
    var samples = raw
    let fade = min(samples.count / 4, Int(0.03 * rate))
    for i in 0..<fade { samples[samples.count - 1 - i] *= Double(i) / Double(fade) }
    let maxValue = samples.map(abs).max() ?? 1
    return samples.map { Float($0 / max(maxValue, 1e-9) * peak) }
}

func write(_ name: String, _ samples: [Float]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let url = outDir.appendingPathComponent("\(name).caf")
    try? FileManager.default.removeItem(at: url)
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    print("wrote \(name).caf  \(String(format: "%.0f", Double(samples.count) / rate * 1000)) ms")
}

func render(length: Double, peak: Double, _ build: (inout [Double]) -> Void) -> [Float] {
    var samples = [Double](repeating: 0, count: Int(length * rate))
    build(&samples)
    return finish(samples, peak: peak)
}

// MARK: Sets (pitches: D5 587.33, F#5 739.99, A5 880, C5 523.25, G5 783.99, E5 659.26, B5 987.77)

// 1. Soft Bells: a rising fifth that opens, then falls to resolve.
try write("bells-start", render(length: 0.55, peak: 0.30) { s in
    addNote(Note(frequency: 587.33, gain: 0.8, decay: 0.16), into: &s)
    addNote(Note(frequency: 880.00, start: 0.075, gain: 0.65, decay: 0.22), into: &s)
})
try write("bells-stop", render(length: 0.5, peak: 0.28) { s in
    addNote(Note(frequency: 880.00, gain: 0.6, decay: 0.12), into: &s)
    addNote(Note(frequency: 587.33, start: 0.07, gain: 0.8, decay: 0.2), into: &s)
})

// 2. Glass: a single crystal tone with a gentle inharmonic shimmer; lower tone to close.
let glass: [(Double, Double, Double)] = [(1, 1, 1), (2.76, 0.12, 0.5), (5.4, 0.03, 0.3)]
try write("glass-start", render(length: 0.7, peak: 0.24) { s in
    addNote(Note(frequency: 987.77, decay: 0.28, attack: 0.006, partials: glass), into: &s)
})
try write("glass-stop", render(length: 0.6, peak: 0.22) { s in
    addNote(Note(frequency: 659.26, decay: 0.22, attack: 0.006, partials: glass), into: &s)
})

// 3. Minimal: the quietest option; a short low pulse, higher to open, lower to close.
let pure: [(Double, Double, Double)] = [(1, 1, 1), (2, 0.08, 0.5)]
try write("minimal-start", render(length: 0.18, peak: 0.26) { s in
    addNote(Note(frequency: 440, decay: 0.035, attack: 0.003, partials: pure), into: &s)
})
try write("minimal-stop", render(length: 0.18, peak: 0.24) { s in
    addNote(Note(frequency: 330, decay: 0.035, attack: 0.003, partials: pure), into: &s)
})

// 4. Pop: a bubble that pops upward to open; two quick, softer pops falling to close.
let bubble: [(Double, Double, Double)] = [(1, 1, 1), (2, 0.12, 0.4)]
try write("pop-start", render(length: 0.22, peak: 0.32) { s in
    addNote(Note(frequency: 420, decay: 0.045, attack: 0.002, partials: bubble, glideTo: 1.9, glideTime: 0.035), into: &s)
})
try write("pop-stop", render(length: 0.26, peak: 0.30) { s in
    addNote(Note(frequency: 620, gain: 0.85, decay: 0.035, attack: 0.002, partials: bubble, glideTo: 0.72, glideTime: 0.03), into: &s)
    addNote(Note(frequency: 470, start: 0.075, gain: 0.7, decay: 0.045, attack: 0.002, partials: bubble, glideTo: 0.72, glideTime: 0.035), into: &s)
})

// Shared cancel: a single muted low tap, barely there.
try write("cancel", render(length: 0.25, peak: 0.16) { s in
    addNote(Note(frequency: 392, decay: 0.07), into: &s)
})
