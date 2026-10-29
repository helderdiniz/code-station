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

    @Test func runningWorkAndOpenQuestionsAnimate() {
        for state: SessionState in [.starting, .streaming] {
            #expect(CursorEffectActivity(session: state, needsInput: false) == .running)
            #expect(CursorEffectActivity(session: state, needsInput: true) == .running)
        }
        for state: SessionState in [.waiting, .reconnecting("retrying"), .stalled, .stopping] {
            #expect(CursorEffectActivity(session: state, needsInput: false) == .waiting)
            #expect(CursorEffectActivity(session: state, needsInput: true) == .running)
        }
        #expect(CursorEffectActivity(session: .idle, needsInput: false) == .finished)
        #expect(CursorEffectActivity(session: .failed("stopped"), needsInput: false) == .inactive)
    }

    @Test(arguments: ["cursor", "pointer", "sparks", "ember", "aurora", "orbit", "ripple", "prism", "facets", "water"])
    func findsCursorEffects(query: String) {
        #expect(SettingsSearchIndex.results(for: query).contains {
            $0.tab == .appearance && $0.target == .appearanceCursorEffects
        })
    }

    @Test func shortcutsKeepTheirOriginalAssignmentsAndAddTheTwoEffects() {
        let effects: [CursorEffect] = [.none, .ember, .aurora, .orbit, .ripple, .prism]
        #expect(CursorEffect.allCases == effects)
        #expect(effects.map(\.rawValue) == ["none", "ember", "aurora", "orbit", "ripple", "prism"])
        for (index, effect) in effects.enumerated() {
            #expect(CursorEffect.shortcut(String(index)) == effect)
            #expect(CursorEffect(rawValue: effect.rawValue) == effect)
        }
        for key in ["6", "-1", "01", "x", ""] { #expect(CursorEffect.shortcut(key) == nil) }
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

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none }, [false, true])
    func reducedMotionHasAStillHaloOnlyWhileRunning(effect: CursorEffect, userPreference: Bool) {
        let view = makeView()
        for state: CursorEffectActivity in [.running, .waiting, .finished] {
            configure(view, effect: effect, activity: state, reduced: !userPreference, userReduced: userPreference)
            view.movePointer(to: CGPoint(x: 100, y: 100))
            #expect(animations(view).isEmpty)
            let marks = layers(view).compactMap { $0 as? CAShapeLayer }
            #expect(state == .running ? !marks.isEmpty : marks.isEmpty)
        }
    }

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none })
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

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none })
    func waitingStopsEmissionAndCompletionPlaysOnlyOnce(effect: CursorEffect) {
        let view = makeView()
        configure(view, effect: effect, activity: .running)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        configure(view, effect: effect, activity: .waiting)
        #expect(animations(view).isEmpty)
        configure(view, effect: effect, activity: .finished)
        let rings = layers(view).filter { $0.animationKeys()?.contains("ring") == true }
        #expect(rings.count == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1))
        configure(view, effect: effect, activity: .finished)
        #expect(layers(view).filter { $0.animationKeys()?.contains("ring") == true }.count == rings.count)
        configure(view, effect: .none, activity: .finished)
        #expect(animations(view).isEmpty)
    }

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none })
    func pointerExitLetsTrailsDecayWithoutInterruptingThemOnReentry(effect: CursorEffect) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: effect, activity: .running)
        let start = CACurrentMediaTime()
        view.movePointer(to: CGPoint(x: 100, y: 100), at: start)
        view.movePointer(to: CGPoint(x: 120, y: 100), at: start + 0.2)
        let trails = layers(view).filter { $0.animation(forKey: "decay") != nil }
        #expect(!trails.isEmpty)

        view.mouseExited(with: try exitEvent())
        #expect(layers(view).count == trails.count + 2)
        for trail in trails {
            let decay = try #require(trail.animation(forKey: "decay"))
            #expect(decay.duration > 0 && decay.duration.isFinite)
            #expect(decay.repeatCount == 0 && decay.isRemovedOnCompletion)
            #expect(trail.opacity == 0)
            let opacity = (decay as? CAAnimationGroup)?.animations?
                .compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "opacity" }
                ?? decay as? CABasicAnimation
            #expect(try #require(opacity?.toValue as? Double) == 0)
        }

        view.movePointer(to: CGPoint(x: 350, y: 200), at: start + 0.4)
        #expect(layers(view).filter { $0.animation(forKey: "decay") != nil }.count == trails.count)
        #expect(trails.allSatisfy { $0.animation(forKey: "decay") != nil })
        view.movePointer(to: CGPoint(x: 370, y: 200), at: start + 0.6)
        let fresh = layers(view).filter { layer in
            layer.animation(forKey: "decay") != nil && !trails.contains { $0 === layer }
        }
        #expect(!fresh.isEmpty)
        if effect == .aurora {
            for ribbon in fresh.compactMap({ $0 as? CAShapeLayer }) {
                #expect(try #require(ribbon.path).boundingBoxOfPath.minX >= 350)
            }
        }

        view.mouseExited(with: try exitEvent())
        view.setForeground(false)
        #expect(animations(view).isEmpty)
        view.stop()
        #expect(animations(view).isEmpty)
    }

    @Test(arguments: CursorEffect.allCases)
    func reducedMotionPointerExitLeavesNoEffects(effect: CursorEffect) throws {
        let view = makeView()
        for activity: CursorEffectActivity in [.running, .waiting] {
            configure(view, effect: effect, activity: activity, reduced: true)
            view.movePointer(to: CGPoint(x: 100, y: 100))
            view.mouseExited(with: try exitEvent())
            #expect(animations(view).isEmpty)
            #expect(layers(view).count == 2)
        }
    }

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none })
    func questionPromptKeepsTheTrailGoing(effect: CursorEffect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: effect, activity: CursorEffectActivity(session: .streaming, needsInput: false))
        let start = CACurrentMediaTime()
        view.movePointer(to: CGPoint(x: 100, y: 100), at: start)
        view.movePointer(to: CGPoint(x: 120, y: 100), at: start + 0.2)
        let trails = layers(view).filter { $0.animation(forKey: "decay") != nil }
        #expect(!trails.isEmpty)

        configure(view, effect: effect, activity: CursorEffectActivity(session: .streaming, needsInput: true))
        #expect(trails.allSatisfy { $0.animation(forKey: "decay") != nil })
        view.movePointer(to: CGPoint(x: 350, y: 200), at: start + 0.4)
        view.movePointer(to: CGPoint(x: 370, y: 200), at: start + 0.6)
        let fresh = layers(view).filter { layer in
            layer.animation(forKey: "decay") != nil && !trails.contains { $0 === layer }
        }
        #expect(!fresh.isEmpty)
    }

    @Test func enablingReduceMotionAtAQuestionClearsTrailsImmediately() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: .aurora, activity: .running)
        let start = CACurrentMediaTime()
        view.movePointer(to: CGPoint(x: 100, y: 100), at: start)
        view.movePointer(to: CGPoint(x: 120, y: 100), at: start + 1.0 / 60)
        #expect(!animations(view).isEmpty)
        configure(view, effect: .aurora, activity: .waiting, reduced: true)
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

    @Test(arguments: [CursorEffect.ripple, .prism])
    func newEffectsDecayAtRestAndReuseThePool(effect: CursorEffect) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: effect, activity: .running)
        let start = CACurrentMediaTime()
        view.movePointer(to: CGPoint(x: 100, y: 100), at: start)
        view.movePointer(to: CGPoint(x: 140, y: 100), at: start + 0.2)
        let emitted = layers(view).filter { $0.animation(forKey: "decay") != nil }
        #expect(emitted.count == (effect == .ripple ? 1 : 3))
        view.movePointer(to: CGPoint(x: 140, y: 100), at: start + 1)
        #expect(layers(view).filter { $0.animation(forKey: "decay") != nil }.count == emitted.count)
        view.leavePointer()
        for particle in emitted {
            let decay = try #require(particle.animation(forKey: "decay"))
            #expect(decay.repeatCount == 0 && decay.isRemovedOnCompletion)
            #expect(particle.opacity == 0)
        }
        for index in 0..<500 {
            view.movePointer(to: CGPoint(x: 50 + index * 19 % 400, y: 50 + index * 13 % 200),
                             at: start + 2 + Double(index) * 0.2)
            view.click()
        }
        #expect(layers(view).count == CursorEffectLayerView.particleLimit + 2)
        #expect(layers(view).allSatisfy { layer in
            (layer.animationKeys() ?? []).allSatisfy { layer.animation(forKey: $0)?.repeatCount == 0 }
        })
        view.setForeground(false)
        view.click()
        view.movePointer(to: CGPoint(x: 200, y: 200))
        #expect(animations(view).isEmpty)
    }

    @Test func rippleClickHasThreeStaggeredRingsWithBoundedRadius() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        view.configure(settings: CursorEffectsSettings(effect: .ripple, intensity: 1), activity: .running, reduceMotion: false)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        view.click()
        let rings = layers(view).compactMap { $0.name == "ripple-ring" ? $0 as? CAShapeLayer : nil }
        #expect(rings.count == 3)
        let decays = try rings.map { try #require($0.animation(forKey: "decay") as? CAAnimationGroup) }
        #expect(decays.allSatisfy { $0.duration == 1.25 })
        #expect(decays[2].beginTime > decays[1].beginTime)
        #expect(rings.allSatisfy { ($0.path?.boundingBoxOfPath.width ?? 0) <= 200 })
        #expect(rings.allSatisfy { $0.fillColor == nil })
    }

    @Test func prismClickHasSevenTranslucentFacetsAndSeparateSpectralEdges() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: .prism, activity: .running)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        view.click()
        let facets = layers(view).compactMap { $0.name == "prism-facet" ? $0 as? CAShapeLayer : nil }
        let edges = layers(view).compactMap { $0.name == "prism-edge" ? $0 as? CAShapeLayer : nil }
        #expect(facets.count == 7)
        #expect(edges.count == 14)
        #expect(facets.allSatisfy { ($0.fillColor?.alpha ?? 0) > 0 && ($0.fillColor?.alpha ?? 1) < 0.3 })
        #expect(edges.allSatisfy { $0.fillColor == nil && $0.strokeColor != nil })
        for facet in facets {
            let decay = try #require(facet.animation(forKey: "decay"))
            #expect((0.5...0.8).contains(decay.duration))
        }
    }

    @Test(arguments: CursorEffect.allCases.filter { $0 != .none })
    func previewSamplesAreFiniteAndInterruptible(effect: CursorEffect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView()
        configure(view, effect: effect, activity: .running)
        view.playPreviewSample()
        #expect(layers(view).count < CursorEffectLayerView.particleLimit + 80)
        #expect(layers(view).contains { $0.animation(forKey: "preview-path")?.duration == 3.6 })
        view.leavePointer()
        #expect(!animations(view).contains("preview-path"))
        view.movePointer(to: CGPoint(x: 100, y: 100))
        view.movePointer(to: CGPoint(x: 160, y: 100), at: CACurrentMediaTime() + 0.2)
        view.setForeground(false)
        #expect(animations(view).isEmpty)
        configure(view, effect: effect, activity: .running, reduced: true)
        view.setForeground(true)
        view.playPreviewSample()
        view.click()
        #expect(animations(view).isEmpty)
    }

    private func makeView() -> CursorEffectLayerView {
        let view = CursorEffectLayerView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.layoutLayers()
        view.setForeground(true)
        return view
    }

    private func exitEvent() throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
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
