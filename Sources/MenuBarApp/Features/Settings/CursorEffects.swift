import Foundation

enum CursorEffect: String, CaseIterable, Identifiable {
    case none, ember, aurora, orbit

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var subtitle: String {
        switch self {
        case .none: "Keep it simple"
        case .ember: "Golden sparks"
        case .aurora: "A ribbon of light"
        case .orbit: "A constellation"
        }
    }

    var detail: String {
        switch self {
        case .none: "Your cursor stays just as it is, even while a session is running."
        case .ember: "Golden sparks catch your movement, scatter, and cool into nothing."
        case .aurora: "Teal turns to violet as a ribbon of light follows your lead, then fades."
        case .orbit: "Satellites gather around your cursor and leave a dusting of distant stars."
        }
    }
}

struct CursorEffectsSettings: Equatable {
    var effect: CursorEffect = .none
    var intensity: Double = 0.55 {
        didSet { intensity = Self.validIntensity(intensity) }
    }
    var reduceMotion = false

    init(effect: CursorEffect = .none, intensity: Double = 0.55, reduceMotion: Bool = false) {
        self.effect = effect
        self.intensity = Self.validIntensity(intensity)
        self.reduceMotion = reduceMotion
    }

    var intensityLabel: String {
        switch intensity {
        case ..<0.35: "Subtle"
        case ..<0.65: "Balanced"
        case ..<0.85: "Expressive"
        default: "All out"
        }
    }

    private static func validIntensity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0.1, value)) : 0.55
    }
}

enum CursorEffectActivity: Hashable {
    case inactive, running, waiting, finished

    init(session: SessionState, needsInput: Bool) {
        guard session.isBusy else {
            self = session.isFailed ? .inactive : .finished
            return
        }
        if needsInput {
            self = .waiting
        } else {
            switch session {
            case .starting, .streaming: self = .running
            default: self = .waiting
            }
        }
    }

    var title: String {
        switch self {
        case .inactive: "Inactive"
        case .running: "Running"
        case .waiting: "Waiting"
        case .finished: "Finished"
        }
    }
}

extension Preferences {
    static func cursorEffects(in store: UserDefaults = .standard) -> CursorEffectsSettings {
        let values = store.dictionary(forKey: "cursorEffects") ?? [:]
        return CursorEffectsSettings(
            effect: (values["effect"] as? String).flatMap(CursorEffect.init(rawValue:)) ?? .none,
            intensity: values["intensity"] as? Double ?? 0.55,
            reduceMotion: values["reduceMotion"] as? Bool ?? false)
    }

    static func setCursorEffects(_ value: CursorEffectsSettings, in store: UserDefaults = .standard) {
        store.set(["effect": value.effect.rawValue,
                   "intensity": value.intensity,
                   "reduceMotion": value.reduceMotion], forKey: "cursorEffects")
    }
}
