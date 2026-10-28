import AppKit
import Testing
@testable import MenuBarApp

struct CursorEffectsTests {
    @Test func missingAndInvalidPreferencesKeepEffectsOff() {
        let preferences = TestPreferences()
        #expect(Preferences.cursorEffects(in: preferences.store) == CursorEffectsSettings())
        for value: Any in ["ember", ["effect": "unknown"], ["effect": 1], ["effect": ""], ["intensity": 1]] {
            preferences.store.set(value, forKey: "cursorEffects")
            #expect(Preferences.cursorEffects(in: preferences.store).effect == .none)
        }
    }

    @Test func intensityIsFiniteAndBounded() {
        #expect(CursorEffectsSettings(intensity: .nan).intensity == 0.55)
        #expect(CursorEffectsSettings(intensity: .infinity).intensity == 0.55)
        #expect(CursorEffectsSettings(intensity: -10).intensity == 0.1)
        #expect(CursorEffectsSettings(intensity: 10).intensity == 1)
        var settings = CursorEffectsSettings()
        settings.intensity = .nan
        #expect(settings.intensity == 0.55)
    }

    @MainActor @Test func choicesPersistIndependentlyAndResetRestoresDefaults() {
        let scratch = ScratchDirectory()
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratch.preferences.store)
        settings.cursorEffects.intensity = 0.83
        settings.cursorEffects.reduceMotion = true
        for effect in CursorEffect.allCases {
            settings.cursorEffects.effect = effect
            let restored = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratch.preferences.store)
            #expect(restored.cursorEffects == CursorEffectsSettings(effect: effect, intensity: 0.83, reduceMotion: true))
        }
        let previous = settings.cursorEffects
        settings.resetAppearance()
        #expect(Preferences.cursorEffects(in: scratch.preferences.store) == CursorEffectsSettings())
        settings.cursorEffects = previous
        #expect(Preferences.cursorEffects(in: scratch.preferences.store) == previous)
    }

    @Test func onlyRunningWorkAnimatesAndQuestionsTakePrecedence() {
        for state: SessionState in [.starting, .streaming] {
            #expect(CursorEffectActivity(session: state, needsInput: false) == .running)
            #expect(CursorEffectActivity(session: state, needsInput: true) == .waiting)
        }
        for state: SessionState in [.waiting, .reconnecting("retrying"), .stalled, .stopping] {
            #expect(CursorEffectActivity(session: state, needsInput: false) == .waiting)
        }
        #expect(CursorEffectActivity(session: .idle, needsInput: false) == .finished)
        #expect(CursorEffectActivity(session: .failed("stopped"), needsInput: false) == .inactive)
    }

    @Test(arguments: ["cursor", "pointer", "sparks", "ember", "aurora", "orbit"])
    func findsCursorEffects(query: String) {
        #expect(SettingsSearchIndex.results(for: query).contains {
            $0.tab == .appearance && $0.target == .appearanceCursorEffects
        })
    }

    @Test func textSearchGoesToTextBelowTheCursorEffects() {
        #expect(SettingsSearchIndex.results(for: "session text").first?.target == .appearanceText)
    }

    @MainActor @Test func detachedOverlaysHaveNoAnimationsOrHitTargets() {
        let view = CursorEffectLayerView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        for effect in CursorEffect.allCases {
            for activity: CursorEffectActivity in [.running, .waiting, .finished, .inactive] {
                view.configure(settings: CursorEffectsSettings(effect: effect), activity: activity, reduceMotion: false)
                #expect(view.hitTest(CGPoint(x: 30, y: 30)) == nil)
                #expect(animations(in: view.layer).isEmpty)
            }
        }
        view.stop()
        #expect(animations(in: view.layer).isEmpty)
    }

    @MainActor private func animations(in layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animations(in: $0) }
    }
}

@MainActor
struct CursorEffectLayerTests {
    @Test func noneSuppressesEveryState() {
        let view = makeView()
        for state: CursorEffectActivity in [.running, .waiting, .finished, .running, .inactive] {
            configure(view, effect: .none, activity: state)
            view.movePointer(to: CGPoint(x: 100, y: 100))
            #expect(animations(view).isEmpty)
            #expect(layers(view).count == 2)
        }
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit], [false, true])
    func reducedMotionHasStillHalosAndNoCompletionBurst(effect: CursorEffect, userPreference: Bool) {
        let view = makeView()
        for state: CursorEffectActivity in [.running, .waiting, .finished] {
            configure(view, effect: effect, activity: state, reduced: !userPreference, userReduced: userPreference)
            view.movePointer(to: CGPoint(x: 100, y: 100))
            #expect(animations(view).isEmpty)
            let marks = layers(view).compactMap { $0 as? CAShapeLayer }
            #expect(state == .finished ? marks.isEmpty : !marks.isEmpty)
        }
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit])
    func movementIsBoundedAndWindowChangesRemoveAllAnimations(effect: CursorEffect) {
        let view = makeView()
        configure(view, effect: effect, activity: .running)
        let start = CACurrentMediaTime()
        for index in 0..<500 {
            view.movePointer(to: CGPoint(x: 30 + index * 13 % 400, y: 50 + index * 17 % 200),
                             at: start + Double(index) / 60)
        }
        #expect(layers(view).count < CursorEffectLayerView.particleLimit + 80)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(layers(view).filter { $0.animationKeys()?.contains("decay") == true }.count > 20)
        }
        for layer in layers(view) {
            for key in layer.animationKeys() ?? [] {
                if let group = layer.animation(forKey: key) as? CAAnimationGroup {
                    #expect(group.duration.isFinite && group.duration > 0)
                    #expect(group.animations?.allSatisfy { $0.duration == group.duration } == true)
                }
            }
        }
        #expect(layers(view).allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
        view.setForeground(false)
        #expect(animations(view).isEmpty)
        view.setForeground(true)
        view.stop()
        #expect(animations(view).isEmpty)
    }

    @Test func waitingStopsEmissionAndCompletionPlaysOnlyOnce() {
        let view = makeView()
        configure(view, effect: .orbit, activity: .running)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        configure(view, effect: .orbit, activity: .waiting)
        #expect(animations(view).isEmpty)
        configure(view, effect: .orbit, activity: .finished)
        let rings = layers(view).filter { $0.animationKeys()?.contains("ring") == true }
        #expect(rings.count == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1))
        configure(view, effect: .orbit, activity: .finished)
        #expect(layers(view).filter { $0.animationKeys()?.contains("ring") == true }.count == rings.count)
        configure(view, effect: .none, activity: .finished)
        #expect(animations(view).isEmpty)
    }

    @Test func aDifferentSessionStartsWithoutThePreviousSessionsCompletion() {
        let running = makeView()
        configure(running, effect: .orbit, activity: .running)
        running.movePointer(to: CGPoint(x: 100, y: 100))
        running.stop()
        let finished = makeView()
        configure(finished, effect: .orbit, activity: .finished)
        #expect(animations(running).isEmpty)
        #expect(animations(finished).isEmpty)
    }

    @Test func invalidPointerCoordinatesNeverReachLayers() {
        let view = makeView()
        configure(view, effect: .orbit, activity: .running)
        for point in [CGPoint(x: Double.nan, y: 2), CGPoint(x: 2, y: Double.infinity), CGPoint(x: -10, y: 10)] {
            view.movePointer(to: point)
        }
        #expect(layers(view).allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    @Test func auroraJoinsRibbonSegmentsAndFadesTheirColourAndWidth() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: .aurora, activity: .running)
        let start = CACurrentMediaTime()
        for (index, point) in [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 100), CGPoint(x: 140, y: 120)].enumerated() {
            view.movePointer(to: point, at: start + Double(index) / 60)
        }
        let ribbons = layers(view).compactMap { $0.name == "aurora-ribbon" ? $0 as? CAShapeLayer : nil }
        #expect(ribbons.count == 8)
        let first = try #require(ribbons.first?.path)
        let next = try #require(ribbons.dropFirst(4).first?.path)
        var nextStart = CGPoint.zero
        next.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { nextStart = element.pointee.points[0] }
        }
        #expect(first.currentPoint == nextStart)
        for ribbon in ribbons {
            let tint = try #require(ribbon.animation(forKey: "ribbon-colour") as? CABasicAnimation)
            let taper = try #require(ribbon.animation(forKey: "ribbon-taper") as? CABasicAnimation)
            let fromColour = try #require(tint.fromValue) as! CGColor
            let toColour = try #require(tint.toValue) as! CGColor
            #expect(fromColour != toColour)
            #expect(try #require(taper.fromValue as? Double) > #require(taper.toValue as? Double))
            #expect(ribbon.animation(forKey: "decay") != nil)
        }
    }

    @Test func emberThrowsMoreStreaksWithFasterMovement() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        func sparks(distance: CGFloat, elapsed: Double) -> [CAShapeLayer] {
            let view = makeView()
            configure(view, effect: .ember, activity: .running)
            let start = CACurrentMediaTime()
            view.movePointer(to: CGPoint(x: 100, y: 100), at: start)
            view.movePointer(to: CGPoint(x: 100 + distance, y: 100), at: start + elapsed)
            return layers(view).compactMap { $0.name == "cursor-spark" ? $0 as? CAShapeLayer : nil }
        }
        let slow = sparks(distance: 3, elapsed: 0.1)
        let fast = sparks(distance: 40, elapsed: 1.0 / 60)
        #expect(fast.count > slow.count)
        for spark in fast {
            #expect(spark.fillColor == nil)
            #expect(spark.strokeColor != nil)
            let group = try #require(spark.animation(forKey: "decay") as? CAAnimationGroup)
            let flight = try #require(group.animations?.first as? CAKeyframeAnimation)
            let points = try #require(flight.values as? [NSValue]).map(\.pointValue)
            #expect(points.count > 3)
            let last = points.count - 1
            #expect(points[last].y - points[last - 1].y > points[1].y - points[0].y)
        }
    }

    @Test func orbitHasGlowingSatellitesAndMovingConstellationLinks() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: .orbit, activity: .running)
        #expect(animations(view).isEmpty)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        let satellites = layers(view).filter { $0.name == "orbit-satellite" }
        #expect(satellites.count == 4)
        for satellite in satellites {
            #expect(satellite.sublayers?.contains { $0.name == "cursor-glow" } == true)
            let orbit = try #require(satellite.animation(forKey: "orbit") as? CAKeyframeAnimation)
            let points = try #require(orbit.values as? [NSValue]).map(\.pointValue)
            #expect(abs(try #require(points.first).x - #require(points.last).x) < 0.001)
            #expect(abs(try #require(points.first).y - #require(points.last).y) < 0.001)
        }
        #expect(layers(view).filter { $0.animation(forKey: "constellation") != nil }.count == 1)
        configure(view, effect: .orbit, activity: .waiting)
        #expect(animations(view).isEmpty)
        #expect(layers(view).allSatisfy { $0.name != "cursor-glow" })
    }

    private func makeView() -> CursorEffectLayerView {
        let view = CursorEffectLayerView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.layoutLayers()
        view.setForeground(true)
        return view
    }

    private func configure(_ view: CursorEffectLayerView, effect: CursorEffect,
                           activity: CursorEffectActivity, reduced: Bool = false, userReduced: Bool = false) {
        view.configure(settings: CursorEffectsSettings(effect: effect, reduceMotion: userReduced), activity: activity,
                       reduceMotion: reduced)
    }

    private func layers(_ view: CursorEffectLayerView) -> [CALayer] {
        func descendants(_ layer: CALayer) -> [CALayer] {
            [layer] + (layer.sublayers ?? []).flatMap(descendants)
        }
        return view.layer.map(descendants) ?? []
    }

    private func animations(_ view: CursorEffectLayerView) -> [String] {
        layers(view).flatMap { $0.animationKeys() ?? [] }
    }
}
