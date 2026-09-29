import ObjCSupport
import AVFoundation
import Foundation
import ServiceManagement

// `Driftflow --transcribe <audio file> [--locale en-US] [--dictation-model]` runs the same streaming pipeline headlessly,
// which is handy for testing accuracy and speed without the microphone.
let arguments = CommandLine.arguments
/// Options that run inside the app itself (see DriftflowApp); anything else starting with "--" is
/// a command-line tool below.
let guiOptions: Set<String> = ["--scratch-test", "--hud-demo", "--demo", "--snapshot", "--mic-test", "--tap-test"]

if let index = arguments.firstIndex(of: "--transcribe"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    let locale = arguments.firstIndex(of: "--locale").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ""
    Task { @MainActor in
        exit(await transcribeFile(path: path, localeID: locale, model: arguments.contains("--dictation-model") ? .dictation : .automatic))
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--file"), index + 1 < arguments.count {
    // `Driftflow --file <audio or video> [--format text|timestamped|srt|vtt] [--apple] [--v2]`: the
    // "Transcribe Files" pipeline headlessly; prints the transcript, with timing on stderr.
    let url = URL(fileURLWithPath: arguments[index + 1])
    let format = arguments.firstIndex(of: "--format").flatMap { $0 + 1 < arguments.count ? FileTranscript.Format(rawValue: arguments[$0 + 1]) : nil } ?? .text
    Task { @MainActor in
        let clock = ContinuousClock()
        do {
            let engine: FileTranscription.Engine
            if arguments.contains("--apple") {
                engine = .apple(SpeechConfig(language: "en", accent: "US", model: .automatic, vocabulary: []))
            } else {
                let parakeet = ParakeetEngine()
                let model: AccuracyModel = arguments.contains("--v2") ? .parakeetV2 : .parakeetUnified
                if let index = arguments.firstIndex(of: "--vocab"), index + 1 < arguments.count {
                    await parakeet.setVocabulary(arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                }
                try await parakeet.load(model) { _ in }
                if let error = await parakeet.vocabularyError { FileHandle.standardError.write(Data("[vocab] \(error)\n".utf8)) }
                if arguments.contains("--vocab") { FileHandle.standardError.write(Data("[vocab] boosting active: \(await parakeet.boostingActive)\n".utf8)) }
                engine = .parakeet(parakeet, model)
            }
            if arguments.contains("--plain"), case .parakeet(let parakeet, _) = engine {
                // Whole file through the dictation path (`transcribe`), as a final pass would.
                let reader = try await AudioDecoder.open(url)
                var samples: [Float] = []
                while let block = try await reader.nextBlock() { samples += block }
                let t0 = clock.now
                let text = try await parakeet.transcribe(samples) ?? ""
                print(text)
                FileHandle.standardError.write(Data("[plain] \(Int((clock.now - t0).components.attoseconds / 1_000_000_000_000_000 + (clock.now - t0).components.seconds * 1000)) ms\n".utf8))
                exit(0)
            }
            var chunks = 0
            // `--copies N`: transcribe with N copies of the model side by side, as the app does (3).
            let copies = arguments.firstIndex(of: "--copies").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 1
            var helpers: [ParakeetEngine] = []
            if case .parakeet(_, let model) = engine, copies > 1 {
                for _ in 1..<copies {
                    let helper = ParakeetEngine()
                    if let index = arguments.firstIndex(of: "--vocab"), index + 1 < arguments.count {
                        await helper.setVocabulary(arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    }
                    try await helper.load(model) { _ in }
                    helpers.append(helper)
                }
            }
            let start = clock.now
            let segments = try await FileTranscription.run(url, engine: engine, helpers: { [helpers] in helpers }) { _ in chunks += 1 }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let duration = await AudioDecoder.duration(of: url) ?? segments.last?.end ?? 0
            let transcript = FileTranscript(id: UUID(), fileName: url.lastPathComponent, path: url.path, created: Date(),
                                            duration: duration, processingSeconds: seconds, engine: "", segments: segments)
            print(transcript.export(format), terminator: "")
            FileHandle.standardError.write(Data(String(format: "[file] %.1f s audio in %.2f s (%.0fx), %d progress updates, %d segments, %d words\n",
                                                       duration, seconds, duration / max(seconds, 0.001), chunks, segments.count, transcript.wordCount).utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("[file] error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--rescue-roundtrip"), index + 1 < arguments.count {
    // Saves a recording the way a failed dictation is kept, reads it back, and transcribes both.
    Task { @MainActor in
        do {
            let reader = try await AudioDecoder.open(URL(fileURLWithPath: arguments[index + 1]))
            var samples: [Float] = []
            while let block = try await reader.nextBlock() { samples += block }
            guard let name = RescueAudio.save(samples) else { print("save failed"); exit(1) }
            let url = RescueAudio.url(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let back = try await AudioDecoder.open(url)
            var restored: [Float] = []
            while let block = try await back.nextBlock() { restored += block }
            let maxError = zip(samples, restored).map { abs($0 - $1) }.max() ?? 1
            let parakeet = ParakeetEngine()
            try await parakeet.load(.parakeetUnified) { _ in }
            let original = try await parakeet.transcribe(samples) ?? ""
            let recovered = try await parakeet.transcribe(restored) ?? ""
            print("samples \(samples.count) → \(restored.count), max error \(maxError), permissions \(String(format: "%o", (attributes[.posixPermissions] as? Int) ?? 0))")
            print("original:  \(original)\nrecovered: \(recovered)\nidentical: \(original == recovered)")
            RescueAudio.delete(name)
            print("deleted: \(!FileManager.default.fileExists(atPath: url.path))")
            exit(0)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
    dispatchMain()
} else if arguments.contains("--duck-crash") {
    // Ducks and exits without restoring, like a crash; `--duck-recover` then runs the launch fix-up.
    Task { @MainActor in
        AudioDucker().duck(to: 0.9)
        try? await Task.sleep(for: .milliseconds(300))
        print("ducked to \(AudioDucker.currentVolume().map { String(format: "%.3f", $0) } ?? "n/a"), exiting without restore")
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--duck-recover") {
    Task { @MainActor in
        AudioDucker.restoreAfterCrash()
        print("after launch fix-up: \(AudioDucker.currentVolume().map { String(format: "%.3f", $0) } ?? "n/a")")
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--mic-priority-test") {
    // Which microphone the priority list picks, with this Mac's real devices.
    Task { @MainActor in
        let inputs = AudioDevices.shared.inputs
        let name = { (id: AudioDeviceID?) in id.flatMap(AudioDevices.uid(of:)).flatMap { uid in inputs.first { $0.uid == uid }?.name } ?? "none" }
        let builtIn = inputs.first { AudioDevices.isBuiltIn($0.id) }
        let other = inputs.first { !AudioDevices.isBuiltIn($0.id) }
        print("mics:", inputs.map(\.name).joined(separator: ", "), "· default:", AudioDevices.shared.defaultInputName, "· lid closed:", AudioDevices.lidClosed())
        var cases: [(String, [String], String)] = [
            ("unplugged first choice falls to the next", ["not-connected-uid", builtIn?.uid ?? ""], builtIn?.name ?? AudioDevices.shared.defaultInputName),
            ("nothing ranked connected → system default", ["not-connected-uid", ""], AudioDevices.shared.defaultInputName),
            ("System default ranked first wins", ["", builtIn?.uid ?? ""], AudioDevices.shared.defaultInputName),
        ]
        if let other, let builtIn {
            cases.append(("first connected in order", [other.uid, builtIn.uid, ""], other.name))
            cases.append(("order respected the other way", [builtIn.uid, other.uid, ""], builtIn.name))
        }
        var failures = 0
        for (label, priority, want) in cases {
            let got = name(AudioDevices.deviceID(forPriority: priority))
            if got != want { failures += 1 }
            print(got == want ? "PASS" : "FAIL", label, "→", got, got == want ? "" : "(want \(want))")
        }
        print(failures == 0 ? "all \(cases.count) passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--style-test"), index + 1 < arguments.count {
    // `Driftflow --style-test <file> [clean|professional|casual]`: each line "category|dictation"
    // through the AI Style rewrite exactly as dictation uses it. Prints the result (or KEPT when
    // the check fell back to the words as said) and the time taken.
    Task { @MainActor in
        let style = arguments.dropFirst(index + 2).first.flatMap(AIStyle.init(rawValue:)) ?? .clean
        guard AIRewriter.shared.isAvailable else { print("AI unavailable: \(AIRewriter.shared.availability)"); exit(1) }
        let lines = (try? String(contentsOfFile: arguments[index + 1], encoding: .utf8))?.split(separator: "\n") ?? []
        let clock = ContinuousClock()
        var kept = 0, total = 0, slowest = Duration.zero, sum = Duration.zero
        for line in lines where !line.hasPrefix("#") && line.contains("|") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            AIRewriter.shared.prepare(style)
            try? await Task.sleep(for: .milliseconds(300)) // as if you were still talking
            let start = clock.now
            let result = await AIRewriter.shared.rewrite(parts[1], style: style)
            let took = clock.now - start
            total += 1; sum += took; slowest = max(slowest, took)
            if result == nil { kept += 1 }
            print("[\(parts[0])] \(took.formatted(.units(allowed: [.milliseconds])))\n  said: \(parts[1])\n  \(result.map { "→ " + $0.replacingOccurrences(of: "\n", with: "⏎") } ?? "KEPT")")
        }
        print("\(total) dictations, \(kept) kept as said, mean \((sum / max(total, 1)).formatted(.units(allowed: [.milliseconds]))), slowest \(slowest.formatted(.units(allowed: [.milliseconds])))")
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--log-test") {
    // DRIFTFLOW_LOG_PATH=<scratch file> Driftflow --log-test: writes to that file, never the real log.
    guard ProcessInfo.processInfo.environment["DRIFTFLOW_LOG_PATH"] != nil else { print("Set DRIFTFLOW_LOG_PATH"); exit(2) }
    AppLog.noteHowLastSessionEnded()
    AppLog.info("Dictation started (hold · microphone Test Mic · in TextEdit)")
    AppLog.error("Microphone disconnected: test")
    print(AppLog.report())
    exit(0)
} else if arguments.contains("--smart-test") {
    // Group C logic without a microphone: snippets, per-app rules, plain text, correction learning
    // and the AI Style answer check.
    MainActor.assumeIsolated {
        var failures = 0, total = 0
        func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            total += 1
            let pass = "\(got)" == "\(want)"
            if !pass { failures += 1 }
            print(pass ? "PASS" : "FAIL", name, pass ? "" : "(got \"\(got)\", want \"\(want)\")")
        }
        // AVAudioEngine raises an Objective-C exception for a bad tap (the crash in onboarding's
        // microphone meter); it must come back as an error. A second tap on one bus raises it.
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        let mixerFormat = mixer.outputFormat(forBus: 0)
        let first = DFCatchException { mixer.installTap(onBus: 0, bufferSize: 512, format: mixerFormat) { _, _ in } }
        let second = DFCatchException { mixer.installTap(onBus: 0, bufferSize: 512, format: mixerFormat) { _, _ in } }
        check("audio: a good tap installs", first == nil, true)
        check("audio: an engine exception becomes an error", second != nil, true)
        mixer.removeTap(onBus: 0)

        let named = TextProcessor(vocabulary: ["Driftflow"])
        for spoken in ["I use drift flow daily.", "I use Drift-Flow daily.", "I use DriftFlow daily."] {
            check("app name: \(spoken)", named.process(spoken), "I use Driftflow daily.")
        }
        check("app name: built in", AppSettings.shared.spellingTerms.contains("Driftflow"), true)
        let sig = Snippet(trigger: "my signature", text: "Best,\nAlex")
        let addr = Snippet(trigger: "Office address", text: "12 Main St")
        check("snippet: whole phrase", Snippet.match("My signature.", in: [sig, addr])?.text ?? "-", sig.text)
        check("snippet: fillers and case", Snippet.match("Um, office address!", in: [sig, addr])?.text ?? "-", addr.text)
        check("snippet: not inside a sentence", Snippet.match("Please add my signature at the end", in: [sig]) == nil, true)
        let dated = Snippet(trigger: "t", text: "{day} {date} {clipboard}")
        let day = Date(timeIntervalSince1970: 1_790_380_800) // Sat 26 Sep 2026
        check("snippet: placeholders", dated.expanded(now: day, clipboard: "X").hasSuffix(" X"), true)
        check("snippet: {day}", dated.expanded(now: day, clipboard: "").contains(day.formatted(.dateTime.weekday(.wide))), true)

        let rules = [AppRule(bundleID: "com.googlecode.iterm2", name: "iTerm", style: .literal, plainText: true),
                     AppRule(bundleID: "com.google.Chrome", name: "Chrome", style: .clean),
                     AppRule(website: "mail.google.com", name: "Gmail", style: .professional),
                     AppRule(website: "slack.com", name: "Slack web", style: .casual, pressReturn: true)]
        func resolve(_ id: String?, _ host: String?) -> EffectiveRules {
            EffectiveRules.resolve(rules, target: DictationTarget(bundleID: id, host: host), defaultStyle: .clean)
        }
        check("rule: app", resolve("com.googlecode.iterm2", nil).plainText, true)
        check("rule: website beats its browser", resolve("com.google.Chrome", "mail.google.com").style.rawValue, "professional")
        check("rule: subdomain", resolve("com.apple.Safari", "acme.slack.com").pressReturn, true)
        check("rule: browser without matching site", resolve("com.google.Chrome", "github.com").style.rawValue, "clean")
        check("rule: lookalike domain doesn't match", resolve("com.apple.Safari", "notslack.com").ruleName ?? "none", "none")
        check("rule: none", resolve("com.apple.TextEdit", nil) == EffectiveRules(style: .clean), true)
        check("host: normalized", AppRule.normalizedHost(" https://www.Mail.Google.com/u/0 "), "mail.google.com")

        check("plain: drops period, lowercases", TextProcessor.plain("Git status.", vocabulary: []), "git status")
        check("plain: keeps I", TextProcessor.plain("I think so.", vocabulary: []), "I think so")
        check("plain: keeps acronym", TextProcessor.plain("NPM install.", vocabulary: []), "NPM install")
        check("plain: keeps vocabulary", TextProcessor.plain("Driftflow build.", vocabulary: ["Driftflow"]), "Driftflow build")
        check("plain: keeps two sentences", TextProcessor.plain("Run it. Then stop.", vocabulary: []), "run it. Then stop.")

        @MainActor func learn(_ before: String, _ after: String, _ dictated: String) -> CorrectionWatcher.Change {
            CorrectionWatcher.classify(from: before, to: after, inserted: (before as NSString).range(of: dictated))
        }
        check("learn: misheard name", learn("Deploy it to cooper netties today.", "Deploy it to Kubernetes today.", "Deploy it to cooper netties today."),
              CorrectionWatcher.Change.term("Kubernetes"))
        check("learn: respelled", learn("Ask open AI about it", "Ask OpenAI about it", "Ask open AI about it"), CorrectionWatcher.Change.term("OpenAI"))
        check("learn: ordinary word fix ignored", learn("I went their yesterday", "I went there yesterday", "I went their yesterday"),
              CorrectionWatcher.Change.rewritten)
        check("learn: capitalized at sentence start isn't a name", learn("Their plan works.", "There plan works.", "Their plan works."),
              CorrectionWatcher.Change.rewritten)
        check("learn: unknown word at sentence start", learn("Figure opened.", "Figma opened.", "Figure opened."), CorrectionWatcher.Change.term("Figma"))
        check("learn: rewording ignored", learn("We should ship it", "We must ship it", "We should ship it"), CorrectionWatcher.Change.rewritten)
        check("learn: typing after the dictation keeps watching", learn("Hello there", "Hello there, friend", "Hello there"),
              CorrectionWatcher.Change.elsewhere(NSRange(location: 0, length: 11)))
        check("learn: typing before shifts it", learn("A: Hello there", "AB: Hello there", "Hello there"),
              CorrectionWatcher.Change.elsewhere(NSRange(location: 4, length: 11)))
        check("learn: edit outside the dictation ignored", learn("Old text. Hello there", "Odd text. Hello there", "Hello there"),
              CorrectionWatcher.Change.elsewhere(NSRange(location: 10, length: 11)))

        check("guard: answer rejected", AIRewriter.acceptable("Paris", for: "what is the capital of France", style: .clean), false)
        check("guard: answer sentence rejected", AIRewriter.acceptable("The capital of France is Paris.", for: "what is the capital of France", style: .clean), false)
        check("guard: refusal rejected", AIRewriter.acceptable("I'm sorry, but I can't help with that.", for: "Delete all my files.", style: .professional), false)
        check("guard: email scaffolding rejected", AIRewriter.acceptable("Hi team,\n\nThe launch slips a week.\n\nBest regards,\n[Your Name]", for: "the launch slips a week", style: .professional), false)
        check("guard: correction accepted", AIRewriter.acceptable("Let's meet at 4 PM tomorrow.", for: "lets meet at three no actually four pm tomorrow", style: .clean), true)
        check("guard: question kept", AIRewriter.acceptable("Where did you put the keys?", for: "where did you put the keys", style: .clean), true)
        check("guard: poem rejected", AIRewriter.acceptable("Cats are soft,\nThey purr all day,\nIn sunny spots\nThey love to lay.", for: "write me a poem about cats", style: .casual), false)
        print(failures == 0 ? "all \(total) passed" : "\(failures) of \(total) failed")
        exit(failures == 0 ? 0 : 1)
    }
} else if arguments.contains("--edit-test") {
    // Voice editing's rewrite step on a few typical selections and spoken instructions.
    Task { @MainActor in
        let text = "hey team so the release is gonna be delayed because we found a bug in the login flow and QA needs more time to test the fix, we think it will be ready by thursday but it could slip to friday"
        let cases = [(text, "Make this shorter."), (text, "Make it more professional."), (text, "Turn this into bullet points."),
                     ("Their going to the store tomorow and they buys milk.", "Fix the grammar."),
                     ("The meeting is at 3 PM.", "Translate this into Spanish."),
                     ("We shipped the new onboarding flow.", "What does this mean?")]
        let clock = ContinuousClock()
        for (selection, instruction) in cases {
            let start = clock.now
            do {
                let result = try await AIRewriter.shared.edit(selection, instruction: instruction)
                print("[\(instruction)] \((clock.now - start).formatted(.units(allowed: [.milliseconds])))\n  → \(result.replacingOccurrences(of: "\n", with: "⏎"))")
            } catch { print("[\(instruction)] ERROR \(error.localizedDescription)") }
        }
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--logic-test") {
    // Every key decision in TriggerLogic, including the edge cases found in review.
    typealias T = TriggerLogic
    let cases: [(String, T.Event, T.State, T.Config, T.Action)] = [
        ("press when idle starts", .triggerDown(at: 0), T.State(), T.Config(), .start),
        ("quick tap locks hands-free", .triggerUp(at: 0.2), T.State(phase: .listening, pressedAt: 0), T.Config(), .lockHandsFree),
        ("quick tap cancels when tap-for-hands-free is off", .triggerUp(at: 0.2), T.State(phase: .listening, pressedAt: 0),
         T.Config(tapLocksHandsFree: false), .cancel),
        ("hold then release inserts", .triggerUp(at: 1.0), T.State(phase: .listening, pressedAt: 0), T.Config(), .commit),
        ("press in hands-free finishes", .triggerDown(at: 5), T.State(phase: .listening, handsFree: true), T.Config(), .commit),
        ("press while finishing is queued", .triggerDown(at: 5), T.State(phase: .finishing), T.Config(), .queuePress),
        ("Esc while finishing aborts", .otherKey(isEscape: true, triggerHeld: false), T.State(phase: .finishing), T.Config(), .abort),
        ("⌘C while finishing drops the queued press", .otherKey(isEscape: false, triggerHeld: true), T.State(phase: .finishing), T.Config(), .dropQueuedPress),
        ("typing while finishing (key not held) is ignored", .otherKey(isEscape: false, triggerHeld: false), T.State(phase: .finishing), T.Config(), .none),
        ("⌘C while listening cancels silently", .otherKey(isEscape: false, triggerHeld: true), T.State(phase: .listening, pressedAt: 0), T.Config(), .cancel),
        ("Esc while listening cancels", .otherKey(isEscape: true, triggerHeld: false), T.State(phase: .listening, handsFree: true), T.Config(), .cancel),
        ("typing in hands-free keeps listening", .otherKey(isEscape: false, triggerHeld: false), T.State(phase: .listening, handsFree: true), T.Config(), .none),
        ("⌥Space trigger: other keys don't cancel", .otherKey(isEscape: false, triggerHeld: true), T.State(phase: .listening, pressedAt: 0),
         T.Config(modifierOnlyTrigger: false), .none),
    ]
    var failures = 0
    for (name, event, state, config, want) in cases {
        let got = T.decide(event, state: state, config: config)
        if got != want { failures += 1 }
        print(got == want ? "PASS" : "FAIL", name, got == want ? "" : "(got \(got), want \(want))")
    }
    print(failures == 0 ? "all \(cases.count) passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
} else if arguments.contains("--load-test") {
    // Model switching: the vocabulary sequence that used to deadlock, then rapid switches where
    // the last request must win. Each step has a time limit, so a hang shows up as FAIL.
    Task { @MainActor in
        let parakeet = ParakeetEngine()
        func step(_ name: String, seconds: Double = 90, _ body: @escaping @Sendable () async throws -> Void) async -> Bool {
            let work = Task { try await body() }
            let timer = Task { try await Task.sleep(for: .seconds(seconds)); work.cancel() }
            let ok = (try? await work.value) != nil && !work.isCancelled
            timer.cancel()
            print("\(ok ? "PASS" : "FAIL") \(name)")
            return ok
        }
        _ = await step("load Unified with vocabulary") {
            await parakeet.setVocabulary(["Driftflow"])
            try await parakeet.load(.parakeetUnified) { _ in }
        }
        print("   boosting:", await parakeet.boostingActive)
        _ = await step("switch to TDT v2") { try await parakeet.load(.parakeetV2) { _ in } }
        _ = await step("clear vocabulary") { await parakeet.setVocabulary([]) }
        _ = await step("back to Unified (used to hang)") { try await parakeet.load(.parakeetUnified) { _ in } }
        print("   model:", String(describing: await parakeet.model), "ready:", await parakeet.isReady)
        _ = await step("rapid switches v2 → Unified → v2") {
            async let a: Void = parakeet.load(.parakeetUnified) { _ in }
            try await Task.sleep(for: .milliseconds(20))
            async let b: Void = parakeet.load(.parakeetV2) { _ in }
            _ = try await (a, b)
        }
        print("   model:", String(describing: await parakeet.model), "(expected parakeetV2)")
        _ = await step("vocabulary on, then cleared quickly") {
            try await parakeet.load(.parakeetUnified) { _ in }
            await parakeet.setVocabulary(["Driftflow"])
            await parakeet.setVocabulary([])
        }
        print("   boosting:", await parakeet.boostingActive, "(expected false)")
        let speech = try? await parakeet.transcribe([Float](repeating: 0, count: 16_000))
        print("   silence →", speech.map { "\"\($0)\"" } ?? "nil (no model)")
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--login-status") {
    // Whether macOS will open Driftflow at login (Login Items).
    print("login item:", LoginItem.isEnabled ? "enabled" : LoginItem.needsApproval ? "needs approval" : "off", "(raw status \(SMAppService.mainApp.status.rawValue))")
} else if arguments.contains("--duck-test") {
    // Lowers the output volume by 10% for half a second and checks it comes back exactly.
    Task { @MainActor in
        let ducker = AudioDucker()
        let before = AudioDucker.currentVolume()
        ducker.duck(to: 0.9)
        try? await Task.sleep(for: .milliseconds(500))
        let during = AudioDucker.currentVolume()
        let saved = UserDefaults.standard.dictionary(forKey: "duckRestore") != nil
        ducker.restore()
        try? await Task.sleep(for: .milliseconds(100))
        let after = AudioDucker.currentVolume()
        print("before \(before.map { String(format: "%.3f", $0) } ?? "n/a") · during \(during.map { String(format: "%.3f", $0) } ?? "n/a") · crash record \(saved) · after \(after.map { String(format: "%.3f", $0) } ?? "n/a") · restored \(before == after)")
        exit(0)
    }
    dispatchMain()
} else if arguments.contains("--resolve") {
    // `Driftflow --resolve`: prints which Apple model each language/accent choice resolves to.
    Task { @MainActor in
        guard #available(macOS 26.0, *) else {
            print("Apple's speech models need macOS 26; this Mac uses Parakeet only.")
            exit(0)
        }
        for (language, accent) in [("en", ""), ("en", "GB"), ("en", "IN"), ("en", "MY"), ("ms", ""), ("de", ""),
                                   ("fr", ""), ("es", ""), ("pt", ""), ("zh", ""), ("ja", ""), ("sw", "")] {
            let config = SpeechConfig(language: language, accent: accent, model: .automatic, vocabulary: [])
            let resolved = await SpeechEngine.resolve(config)
            print("\(language)\(accent.isEmpty ? "" : "/" + accent) → \(resolved.map { "\($0.0.identifier(.bcp47)) via \($0.1.displayName)" } ?? "unsupported → app falls back to English")")
        }
        exit(0)
    }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--batch"), index + 1 < arguments.count {
    // `Driftflow --batch <dir with manifest.json>`: the full app pipeline (Parakeet + Apple fallback +
    // number style + cleanup) over every clip; writes results_driftflow.json for scoring.
    let dir = URL(fileURLWithPath: arguments[index + 1])
    Task { @MainActor in exit(await transcribeBatch(dir)) }
    dispatchMain()
} else if let unknown = arguments.dropFirst().first(where: { $0.hasPrefix("--") && !guiOptions.contains($0) }) {
    // A test option this build doesn't know (e.g. a stale binary): never fall through to a second
    // full copy of the app, which would answer the dictation key alongside the real one.
    FileHandle.standardError.write(Data("Unknown option \(unknown)\n".utf8))
    exit(2)
} else {
    DriftflowApp.main()
}

/// `--legacy` (or macOS 15): the app's path without Apple's speech model. Parakeet only, with
/// pauses found by `PauseTracker`.
@MainActor
func useAppleSpeech() -> Bool {
    guard #available(macOS 26.0, *), !SpeechEngine.disabledForTesting else { return false }
    return !CommandLine.arguments.contains("--legacy")
}

@MainActor private var cliAppleEngine: AnyObject?

@MainActor
func beginSession(_ config: SpeechConfig, onUpdate: @escaping @MainActor (String, String) -> Void) async throws -> SpeechSession {
    if useAppleSpeech(), #available(macOS 26.0, *) {
        let engine = cliAppleEngine as? SpeechEngine ?? SpeechEngine()
        cliAppleEngine = engine
        return try await engine.begin(config, onUpdate: onUpdate)
    }
    return RecordingSession(language: config.language)
}

@MainActor
func prewarmSession(_ config: SpeechConfig) {
    if #available(macOS 26.0, *) { (cliAppleEngine as? SpeechEngine)?.prewarm(config) }
}

@MainActor
func transcribeBatch(_ dir: URL) async -> Int32 {
    struct Clip: Decodable { let file: String; let text: String }
    let parakeet = ParakeetEngine()
    let processor = TextProcessor()
    let config = SpeechConfig(language: "en", accent: "US", model: .automatic, vocabulary: [])
    let clock = ContinuousClock()
    do {
        if let index = CommandLine.arguments.firstIndex(of: "--vocab"), index + 1 < CommandLine.arguments.count {
            await parakeet.setVocabulary(CommandLine.arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        try await parakeet.load(CommandLine.arguments.contains("--v2") ? .parakeetV2 : .parakeetUnified) { _ in }
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var results: [[String: Any]] = []
        for clip in clips {
            let file = try AVAudioFile(forReading: dir.appendingPathComponent(clip.file))
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let session = try await beginSession(config) { _, _ in }
            let finalizer = SegmentedFinalizer(parakeet: parakeet, recorder: session.recorder)
            session.onPhraseEnd = { finalizer.phraseEnded(at: $0) }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                session.feed(buffer)
            }
            if session is RecordingSession {
                // The clip arrived at once, so find its pauses in one pass (live, PauseDetector polls).
                let env = ProcessInfo.processInfo.environment
                var tracker = PauseTracker(pauseMilliseconds: env["PAUSE_MS"].flatMap(Int.init) ?? 400,
                                           margin: env["PAUSE_MARGIN"].flatMap(Float.init) ?? 9)
                for cut in tracker.consume(session.recorder.take()) { finalizer.phraseEnded(at: Double(cut) / 16_000) }
            }
            let start = clock.now
            let appleTask = Task { try await session.finish() }
            let parakeetText = await finalizer.finish()
            let elapsed = clock.now - start
            let appleText = try await appleTask.value
            let text = processor.process(parakeetText ?? appleText, english: true)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            results.append(["file": clip.file, "ref": clip.text, "hyp": text, "ms": ms, "sec": seconds])
            prewarmSession(config)
        }
        try JSONSerialization.data(withJSONObject: results).write(to: dir.appendingPathComponent("results_driftflow.json"))
        print("wrote \(results.count) results")
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

@MainActor
func transcribeFile(path: String, localeID: String, model: ModelPreference) async -> Int32 {
    let parts = (localeID.isEmpty ? "en-US" : localeID).split(separator: "-").map(String.init)
    let config = SpeechConfig(language: parts[0], accent: parts.count > 1 ? parts[1] : "", model: model, vocabulary: [])
    let clock = ContinuousClock()
    let parakeet = ParakeetEngine()
    let useParakeet = !CommandLine.arguments.contains("--apple-only")
    do {
        if useParakeet {
            try await parakeet.load(CommandLine.arguments.contains("--v2") ? .parakeetV2 : .parakeetUnified) { _ in }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let seconds = Double(file.length) / file.processingFormat.sampleRate

        let realtime = CommandLine.arguments.contains("--realtime")
        var firstPartial: ContinuousClock.Instant?
        let loadStart = clock.now
        var appleFirst: ContinuousClock.Instant?
        let continuous = CommandLine.arguments.contains("model") || !useAppleSpeech()
        let session = try await beginSession(config) { _, _ in
            if appleFirst == nil { appleFirst = clock.now }
            if firstPartial == nil, !continuous { firstPartial = clock.now }
        }
        let finalizer = useParakeet ? SegmentedFinalizer(parakeet: parakeet, recorder: session.recorder) : nil
        if let finalizer { session.onPhraseEnd = { finalizer.phraseEnded(at: $0) } }
        let pauses = PauseDetector()
        var pauseCount = 0
        if session is RecordingSession {
            pauses.start(recorder: session.recorder) { pauseCount += 1; session.onPhraseEnd?($0) }
        }
        // --preview model: the selected model drives the whole live preview (default: Apple, with an early Parakeet start).
        let early = ParakeetPreview()
        var earlyText: String?
        var previewUpdates = 0
        var lastPreview = ""
        if useParakeet {
            early.start(mode: continuous ? .continuous : .early, parakeet: parakeet, recorder: session.recorder,
                        finalizer: continuous ? finalizer : nil, appleHasText: { appleFirst != nil }) { settled, live in
                if firstPartial == nil { firstPartial = clock.now; earlyText = live }
                previewUpdates += 1
                lastPreview = SegmentedFinalizer.join([settled, live])
            }
        }
        let loadTime = clock.now - loadStart

        // --realtime paces the audio like a live microphone (100 ms buffers) so the numbers reflect
        // what a user feels: time to first live text, and delay between releasing the key and final text.
        let runStart = clock.now
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            session.feed(buffer)
            if realtime { try await Task.sleep(for: .milliseconds(100)) }
        }
        early.stop()
        pauses.stop()
        if session is RecordingSession, !realtime, let finalizer {
            var tracker = PauseTracker()
            for cut in tracker.consume(session.recorder.take()) { pauseCount += 1; finalizer.phraseEnded(at: Double(cut) / 16_000) }
        }
        let releaseAt = clock.now
        // Same path as the app: Parakeet over the utterance, Apple's stream finalizing in parallel.
        let appleTask = Task { try await session.finish() }
        let parakeetText = await finalizer?.finish()
        let parakeetAt = clock.now
        let appleText = try await appleTask.value
        let text = parakeetText ?? appleText
        let runTime = clock.now - runStart
        if let parakeetText {
            FileHandle.standardError.write(Data("[parakeet] release → final text \(parakeetAt - releaseAt)\n[apple]    \(appleText)\n".utf8))
        }
        if realtime {
            let partial = firstPartial.map { "\($0 - runStart)" } ?? "none"
            let source = earlyText.map { "Parakeet early preview: \"\($0)\"" } ?? "Apple stream"
            let apple = appleFirst.map { "\($0 - runStart)" } ?? "none"
            FileHandle.standardError.write(Data("[realtime] first live text after \(partial) (\(source)); Apple's first text after \(apple) · release → final text \(clock.now - releaseAt)\n".utf8))
            if continuous {
                FileHandle.standardError.write(Data("[model preview] \(previewUpdates) updates · last preview before release: \"\(lastPreview)\"\n".utf8))
            }
        }

        print(text)
        fflush(stdout)
        let runSeconds = Double(runTime.components.seconds) + Double(runTime.components.attoseconds) / 1e18
        let summary = String(
            format: "\n[%@ · %@] audio %.1fs · model ready in %@ · transcribed in %.2fs (%.0f× real time)\n",
            session.languageCode ?? "?", session is RecordingSession ? "Parakeet only (macOS 15 path), \(pauseCount) pauses" : useParakeet ? "Parakeet final + Apple live" : "Apple only",
            seconds, "\(loadTime)", runSeconds, seconds / max(runSeconds, 0.001)
        )
        FileHandle.standardError.write(Data(summary.utf8))
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}
