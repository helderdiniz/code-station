import Foundation

enum CursorEffect: String, CaseIterable, Identifiable {
    case none, ember, aurora, orbit, ripple, prism

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var entranceName: String {
        switch self {
        case .none: "No entrance"
        case .ember: "Kindle"
        case .aurora: "First light"
        case .orbit: "Assemble"
        case .ripple: "First drop"
        case .prism: "Crystal bloom"
        }
    }

    var entranceDuration: TimeInterval {
        switch self {
        case .none: 0
        case .ember, .ripple: Motion.popDuration * 2
        case .orbit, .prism: Motion.controlDuration * 3
        case .aurora: Motion.popDuration * 3
        }
    }

    var entranceDetail: String {
        switch self {
        case .none: "Your pointer stays just as it is."
        case .ember: "Golden flecks gather, a warm core ignites, then the first sparks drift away."
        case .aurora: "Soft light bands rise, fold together, and become a flowing ribbon."
        case .orbit: "Four satellites arrive in sequence and join their orbit tracks."
        case .ripple: "A pinpoint gathers and releases one delicate wave into stillness."
        case .prism: "Six facets unfold, turn through the light, and settle behind the pointer."
        }
    }

    var subtitle: String {
        switch self {
        case .none: "Keep it simple"
        case .ember: "Golden sparks"
        case .aurora: "A ribbon of light"
        case .orbit: "A constellation"
        case .ripple: "A moment of calm"
        case .prism: "Light, with an edge"
        }
    }

    var detail: String {
        switch self {
        case .none: "Your cursor stays just as it is, even while a session is running."
        case .ember: "Golden sparks catch your movement, scatter, and cool into nothing."
        case .aurora: "Teal turns to violet as a ribbon of light follows your lead, then fades."
        case .orbit: "Satellites gather around your cursor and leave a dusting of distant stars."
        case .ripple: "Fine teal and silver rings follow your path, like a fingertip across water."
        case .prism: "Translucent facets catch your direction and separate into cyan, violet and rose."
        }
    }

    var clickDetail: String {
        switch self {
        case .none: "No additional click animation."
        case .ember: "A small burst of warm sparks scatters from your pointer."
        case .aurora: "A gentle bloom of colour opens around your pointer."
        case .orbit: "A fine ring expands through the constellation."
        case .ripple: "Three wider ripples open out, then softly dissolve."
        case .prism: "A crisp fan of seven facets opens for a moment, then disappears."
        }
    }

    var restDetail: String {
        switch self {
        case .none: "A quiet workspace, all the time."
        case .ember: "The sparks cool and fade away."
        case .aurora: "The ribbon thins and fades into the background."
        case .orbit: "Satellites quietly circle while your session runs."
        case .ripple: "The last wave fades. Everything returns to stillness."
        case .prism: "The last facet catches the light, then fades completely."
        }
    }
}

struct CursorEffectsSettings: Equatable {
    var effect: CursorEffect = .none
    let intensity = 0.55
}

enum CursorEffectActivity: Hashable {
    case inactive, running, waiting, finished

    init(session: SessionState, needsInput: Bool) {
        guard session.isBusy else {
            self = session.isFailed ? .inactive : .finished
            return
        }
        // A question is still live work, so the trail keeps following the pointer while it is answered.
        if needsInput {
            self = .running
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
            effect: (values["effect"] as? String).flatMap(CursorEffect.init(rawValue:)) ?? .none)
    }

    static func setCursorEffects(_ value: CursorEffectsSettings, in store: UserDefaults = .standard) {
        store.set(["effect": value.effect.rawValue], forKey: "cursorEffects")
    }
}
