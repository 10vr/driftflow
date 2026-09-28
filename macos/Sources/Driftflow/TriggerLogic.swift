import Foundation

/// Pure decision logic for the dictation key, kept free of side effects so every tap/hold/chord
/// case can be unit-tested.
///
/// - Hold the key ≥ `tapThreshold`, release → insert (push-to-talk).
/// - Tap it (< `tapThreshold`) → hands-free lock; the next press inserts.
/// - Any other key while a modifier trigger is held (⌘C, ⌘V…) → silent cancel: it was a shortcut.
/// - Esc cancels while listening, and aborts while finishing (e.g. a model download).
enum TriggerLogic {
    enum Phase: Equatable {
        case idle
        case listening
        case finishing
    }

    struct State: Equatable {
        var phase: Phase = .idle
        var handsFree = false
        /// When the key went down for the current dictation (nil if started from the menu).
        var pressedAt: TimeInterval?
    }

    struct Config {
        var tapThreshold: TimeInterval = 0.3
        var tapLocksHandsFree = true
        var modifierOnlyTrigger = true
    }

    enum Event: Equatable {
        case triggerDown(at: TimeInterval)
        case triggerUp(at: TimeInterval)
        case otherKey(isEscape: Bool, triggerHeld: Bool)
    }

    enum Action: Equatable {
        case none
        case start
        case commit
        /// Stop without inserting.
        case cancel
        /// Keep listening after the key is released.
        case lockHandsFree
        /// The key went down while the previous dictation was still finishing.
        case queuePress
        /// Stop immediately even though the previous dictation is still finishing.
        case abort
        /// A shortcut (e.g. Right ⌘ + C) was typed while finishing: that press wasn't meant to dictate.
        case dropQueuedPress
    }

    static func decide(_ event: Event, state: State, config: Config = Config()) -> Action {
        switch (event, state.phase) {
        case (.triggerDown, .idle):
            return .start
        case (.triggerDown, .listening):
            return state.handsFree ? .commit : .none
        case (.triggerDown, .finishing):
            return .queuePress

        case (.triggerUp(let time), .listening):
            guard !state.handsFree, let pressedAt = state.pressedAt else { return .none }
            if time - pressedAt < config.tapThreshold {
                return config.tapLocksHandsFree ? .lockHandsFree : .cancel
            }
            return .commit
        case (.triggerUp, _):
            return .none

        case (.otherKey(let isEscape, let triggerHeld), .finishing):
            if isEscape { return .abort }
            return config.modifierOnlyTrigger && triggerHeld ? .dropQueuedPress : .none
        case (.otherKey(let isEscape, let triggerHeld), .listening):
            if isEscape { return .cancel }
            if config.modifierOnlyTrigger, triggerHeld, !state.handsFree { return .cancel }
            return .none
        case (.otherKey, .idle):
            return .none
        }
    }
}
