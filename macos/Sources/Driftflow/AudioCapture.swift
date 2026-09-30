import Accelerate
@preconcurrency import AVFoundation
import ObjCSupport
import os

/// Microphone capture built for zero-latency starts.
///
/// One AVAudioEngine lives for the whole app. While it runs, the last ~0.5 s of audio is kept in a
/// pre-roll ring, so when recording begins the words you started saying *just before* the key went
/// down are included. The engine can stay warm between dictations (`linger`) or permanently
/// (`alwaysReady`), making back-to-back dictations start instantly.
///
/// Every engine operation runs on `queue`, one at a time and never on the main thread: switching a
/// cold microphone on takes 70–160 ms, and doing that on the main thread held back the pill and
/// the start sound after you pressed the key.
final class AudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case couldNotListen(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .couldNotListen(let reason): "The microphone couldn't be opened (\(reason))."
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.driftflow.microphone", qos: .userInteractive)

    // Only touched on `queue`:
    private var engine = AVAudioEngine()
    /// The microphone the engine was pointed at, or nil while it follows the system default input
    /// by itself. Following the default is what keeps Bluetooth headsets stable: pointing the
    /// engine at the headset opens its speaker side too, and every restart flipped it between its
    /// music and call modes, each flip another device change (a restart loop that lost the audio).
    private var forcedDevice: AudioDeviceID?
    /// Recent device changes while listening (uptime ns), to slow restarts down during a burst.
    private var recentChanges: [UInt64] = []
    private var restartGeneration = 0
    private var restartPending = false
    private var configObserver: NSObjectProtocol?
    private var running = false
    /// Whether the mic should be on (cleared by `cool()`), so a delayed restart after a device
    /// change never turns it back on once you're done.
    private var wanted = false

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let preferred = OSAllocatedUnfairLock(initialState: [String]())
    /// Microphones in order of preference (CoreAudio UIDs; "" = the system default).
    var preferredDeviceUIDs: [String] {
        get { preferred.withLock { $0 } }
        set { preferred.withLock { $0 = newValue } }
    }
    /// Whether the engine is on. Waits for a start or stop already under way.
    var isRunning: Bool { queue.sync { running } }
    /// Loudest buffer since the last `beginRecording`, in dBFS (−160 = nothing at all). Audio thread writes.
    private let peak = OSAllocatedUnfairLock(initialState: Float(-160))
    var peakDecibels: Float { peak.withLock { $0 } }
    /// True once the running engine has delivered audio (false while a Bluetooth/iPhone mic connects).
    private let delivering = OSAllocatedUnfairLock(initialState: false)
    var isDelivering: Bool { delivering.withLock { $0 } }

    /// Called on the audio thread with a 0...1 level while recording.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called on the main thread with how long a cold start took until the first audio arrived.
    var onColdStart: ((Int) -> Void)?
    /// Called on the main thread when the input device changed and the mic couldn't restart.
    var onFailure: ((Error) -> Void)?

    private struct State {
        var pipe: AudioPipe?
        var preroll: [AVAudioPCMBuffer] = []
        var prerollFrames: AVAudioFrameCount = 0
        var prerollLimit: AVAudioFrameCount = 24_000
        var coldStartBegan: UInt64?
    }

    init() { queue.sync { observeConfiguration() } }

    private func observeConfiguration() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
    }

    /// Starts the engine (if needed) without recording; audio flows into the pre-roll ring.
    /// Waits until it's on.
    func warm() throws {
        try queue.sync { try warmNow() }
    }

    private func warmNow() throws {
        guard !running else { return }
        let chosen = selectDevice()
        let input = engine.inputNode
        // The chosen microphone's own format. After switching devices, the node's output format
        // can still describe the previous microphone; a tap at the wrong sample rate makes
        // AVAudioEngine raise an exception (a crash on Macs whose mics run at different rates),
        // and the wrong channel count pads a one-channel mic out to the previous one's eight.
        let hardware = input.inputFormat(forBus: 0)
        let output = input.outputFormat(forBus: 0)
        let format = hardware.sampleRate > 0 && hardware.channelCount > 0
            && (hardware.sampleRate != output.sampleRate || hardware.channelCount != output.channelCount)
            ? hardware : output
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noInputDevice }

        state.withLock {
            $0.coldStartBegan = DispatchTime.now().uptimeNanoseconds
            $0.prerollLimit = AVAudioFrameCount(format.sampleRate * 0.5)
            $0.preroll.removeAll()
            $0.prerollFrames = 0
        }
        // installTap reports problems by raising an exception: turn it into an error instead.
        if let problem = DFCatchException({
            input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                self?.receive(buffer)
            }
        }) {
            AppLog.error("Couldn't listen to the microphone (\(format.sampleRate) Hz, \(format.channelCount) ch): \(problem.localizedDescription)")
            _ = DFCatchException { input.removeTap(onBus: 0) }
            throw CaptureError.couldNotListen(problem.localizedDescription)
        }
        engine.prepare()
        let name = chosen.flatMap(AudioDevices.name(of:)) ?? "unknown"
        AppLog.info("Microphone on: \(name)\(forcedDevice == nil ? " (system default)" : "") at \(Int(format.sampleRate)) Hz, "
            + "\(format.channelCount) ch (device format \(Int(hardware.sampleRate)) Hz)")
        do {
            try engine.start()
        } catch {
            AppLog.error("The microphone didn't start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
        wanted = true
    }

    /// The microphone the engine is using now vs. the one it would pick if started now
    /// (the chosen mic came back, the default changed, a device appeared).
    var isOnPreferredDevice: Bool {
        queue.sync {
            guard running, let chosen = AudioDevices.deviceID(forPriority: preferredDeviceUIDs) else { return true }
            // Following the default: right as long as the default is the one to use.
            return chosen == (forcedDevice ?? AudioDevices.defaultInput())
        }
    }

    /// Points the engine's input at the chosen microphone, or lets it follow the system default
    /// when that's the one to use. Returns the microphone. Only valid while the engine is stopped.
    private func selectDevice() -> AudioDeviceID? {
        guard let chosen = AudioDevices.deviceID(forPriority: preferredDeviceUIDs) else { return nil }
        if chosen == AudioDevices.defaultInput() {
            // An engine once pointed at a device stays on it, so following the default takes a new one.
            if forcedDevice != nil {
                engine = AVAudioEngine()
                observeConfiguration()
                forcedDevice = nil
            }
        } else if let unit = engine.inputNode.audioUnit {
            var device = chosen
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            forcedDevice = chosen
        }
        return chosen
    }

    /// Stops the microphone entirely (the privacy indicator goes away). Returns at once; the
    /// engine stops in the background, before anything asked of it afterwards.
    func cool() {
        queue.async { self.coolNow() }
    }

    private func coolNow() {
        wanted = false
        recentChanges.removeAll()
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        delivering.withLock { $0 = false }
        state.withLock {
            $0.pipe = nil
            $0.preroll.removeAll()
            $0.prerollFrames = 0
        }
    }

    /// Routes audio to `pipe`, starting with the pre-roll captured before this call. Waits until
    /// the microphone is on.
    func beginRecording(into pipe: AudioPipe, includePreroll: Bool) throws {
        try queue.sync { try beginNow(into: pipe, includePreroll: includePreroll) }
    }

    /// As above, without waiting: returns at once and calls `completion` on the main thread once
    /// the microphone is on (nil) or couldn't be opened. Audio from its first moment is kept.
    func beginRecording(into pipe: AudioPipe, includePreroll: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do { try self.beginNow(into: pipe, includePreroll: includePreroll) } catch { failure = error }
            DispatchQueue.main.async { onMainThread { completion(failure) } }
        }
    }

    private func beginNow(into pipe: AudioPipe, includePreroll: Bool) throws {
        try warmNow()
        peak.withLock { $0 = -160 }
        state.withLock { state in
            if includePreroll { state.preroll.forEach(pipe.push) }
            state.preroll.removeAll()
            state.prerollFrames = 0
            state.pipe = pipe
        }
    }

    /// Stops routing audio to the pipe (after a start that's still under way, if there is one).
    func endRecording() {
        queue.async { self.state.withLock { $0.pipe = nil } }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        delivering.withLock { $0 = true }
        let (pipe, began) = state.withLock { state -> (AudioPipe?, UInt64?) in
            let began = state.coldStartBegan
            state.coldStartBegan = nil
            if let pipe = state.pipe { return (pipe, began) }
            // Not recording: keep a rolling window of recent audio.
            guard let copy = buffer.deepCopy() else { return (nil, began) }
            state.preroll.append(copy)
            state.prerollFrames += copy.frameLength
            while state.prerollFrames > state.prerollLimit, let first = state.preroll.first {
                state.prerollFrames -= first.frameLength
                state.preroll.removeFirst()
            }
            return (nil, began)
        }
        if let began {
            let ms = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            DispatchQueue.main.async { [weak self] in self?.onColdStart?(ms) }
        }
        guard let pipe else { return }
        pipe.push(buffer)
        let decibels = Self.decibels(of: buffer)
        peak.withLock { $0 = max($0, decibels) }
        onLevel?(max(0, min(1, (decibels + 50) / 42)))
    }

    /// On `queue`.
    private func handleConfigurationChange() {
        // The input device or its format changed (AirPods connected, default mic switched...).
        // The engine has stopped itself; the recording (if any) carries on once it restarts.
        let listening = running || restartPending
        AppLog.info("Audio devices changed\(listening ? " while listening: restarting the microphone" : "")")
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        guard listening, wanted else { return }
        // Devices can send changes in bursts while they switch: restart right away the first
        // times, then wait for a burst to settle instead of restarting into every step of it.
        let now = DispatchTime.now().uptimeNanoseconds
        recentChanges = recentChanges.filter { now - $0 < 3_000_000_000 } + [now]
        let delay = recentChanges.count > 2 ? 0.6 : 0
        restartGeneration += 1
        restartPending = true
        let generation = restartGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.restartGeneration == generation else { return } // a later change took over
            self.restartPending = false
            guard self.wanted else { return } // cooled meanwhile: stay off
            do {
                try self.warmNow()
            } catch {
                // Devices often report zero channels for a moment while switching; try once more.
                self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.wanted else { return }
                    do {
                        try self.warmNow()
                    } catch {
                        AppLog.error("The microphone couldn't restart after a device change: \(error.localizedDescription)")
                        DispatchQueue.main.async { self.onFailure?(error) }
                    }
                }
            }
        }
    }

    /// RMS level in dBFS (vDSP runs on the Apple Silicon vector units).
    private static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var meanSquare: Float = 0
        vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(buffer.frameLength))
        return 10 * log10(max(meanSquare, 1e-16))
    }
}

/// Thread-safe hand-off between the audio thread and a speech session that may not exist yet.
final class AudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    /// About 60 s of 48 kHz audio in 512-frame buffers; guards against a model that never loads.
    private let maxPending = 6000

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let sink {
            sink(buffer)
        } else if pending.count < maxPending, let copy = buffer.deepCopy() {
            // Tap buffers are reused by the engine, so hold our own copy.
            pending.append(copy)
        }
    }

    /// Replays everything captured so far, then streams live buffers to `sink`.
    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending.forEach(sink)
        pending.removeAll()
        self.sink = sink
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        sink = nil
    }
}
