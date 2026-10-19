import Foundation
import Testing
@testable import MenuBarApp

struct AppMarkMotionTests {
    @Test func everyEntryOffersAllGesturesExceptTheLastOne() {
        var motion = AppMarkMotion()
        #expect(motion.playback == nil)
        for (index, gesture) in AppMarkGesture.allCases.enumerated() {
            let last = motion.lastGesture
            motion.update(.init(hovered: true), at: Double(index)) { choices in
                #expect(choices == AppMarkGesture.allCases.filter { $0 != last })
                #expect(choices.contains(gesture))
                return gesture
            }
            #expect(motion.lastGesture == gesture)
            motion.update(.init(), at: Double(index) + 0.5)
        }
    }

    @Test(arguments: AppMarkGesture.allCases)
    func pointerMovementDoesNotChooseAnotherGesture(_ gesture: AppMarkGesture) {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        for i in 1...10 {
            motion.update(.init(hovered: true, pointer: CGPoint(x: Double(i) / 10, y: -1)),
                          at: Double(i) / 10) { _ in
                Issue.record("Pointer movement must not choose a gesture")
                return .ripple
            }
            #expect(motion.lastGesture == gesture)
        }
    }

    @Test(arguments: [AppMarkGesture.ripple, .orbit, .bloom])
    func finiteGesturesReturnExactlyToRest(_ gesture: AppMarkGesture) {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        #expect(motion.pose(at: 0) == .rest)
        #expect(motion.pose(at: gesture.duration / 2) != .rest)
        #expect(motion.pose(at: gesture.duration) == .rest)
        #expect(motion.pose(at: gesture.duration * 10) == .rest)
        motion.update(.init(), at: 100)
        let later = 1_000_000.123
        motion.update(.init(hovered: true), at: later) { _ in gesture }
        #expect(motion.pose(at: later + gesture.duration) == .rest)
    }

    @Test func magneticFieldFollowsThenHoldsWithoutMorePlayback() throws {
        var motion = AppMarkMotion()
        let input = AppMarkMotion.Input(hovered: true, pointer: CGPoint(x: 1, y: -1))
        motion.update(input, at: 0) { _ in .magnetic }
        let held = motion.pose(at: 0.3)
        #expect(held.tiltY == 9)
        #expect(held.tiltX == 7)
        #expect(abs((held.dots[2].x - AppMarkPose.rest.dots[2].x) * 41 - 2.255) < 0.001)
        #expect(motion.pose(at: 20) == held)
        let stationary = motion.update(input, at: 20)
        #expect(!stationary)

        let moved = AppMarkMotion.Input(hovered: true, pointer: CGPoint(x: -1, y: 1))
        let follows = motion.update(moved, at: 20)
        #expect(follows)
        #expect(motion.pose(at: 20) == held)
        let playback = try #require(motion.playback)
        #expect(motion.pose(at: 20 + playback.duration).tiltY == -9)
        #expect(motion.pose(at: 21) == motion.pose(at: 40))
    }

    @Test(arguments: AppMarkGesture.allCases)
    func exitAndRapidReentryBlendFromTheCurrentPose(_ gesture: AppMarkGesture) throws {
        var motion = AppMarkMotion()
        motion.update(.init(hovered: true), at: 0) { _ in gesture }
        let beforeExit = motion.pose(at: 0.25)
        motion.update(.init(), at: 0.25)
        #expect(motion.pose(at: 0.25) == beforeExit)
        #expect(motion.pose(at: 0.44) == .rest)

        let beforeReentry = motion.pose(at: 0.3)
        motion.update(.init(hovered: true), at: 0.3) { $0.first! }
        #expect(motion.lastGesture != gesture)
        #expect(motion.pose(at: 0.3) == beforeReentry)
        let playback = try #require(motion.playback)
        #expect(motion.pose(at: 0.42) == playback.gesture?.pose(at: (0.42 - playback.start) / playback.duration,
                                                            pointer: playback.pointer))
        motion.update(.init(), at: 0.42)
        #expect(motion.pose(at: 1) == .rest)
    }

    @Test func visibleKeyboardFocusStartsOnceAndKeepsTheGestureAfterPointerExit() {
        var motion = AppMarkMotion()
        motion.update(.init(focused: true), at: 0) { _ in .bloom }
        #expect(motion.lastGesture == .bloom)
        let staysFocused = motion.update(.init(focused: true), at: 0.1)
        #expect(!staysFocused)
        motion.update(.init(hovered: true, focused: true), at: 0.2) { _ in .orbit }
        #expect(motion.lastGesture == .orbit)
        let pointerExited = motion.update(.init(focused: true), at: 0.3)
        #expect(!pointerExited)
        #expect(motion.playback?.gesture == .orbit)
        motion.update(.init(), at: 0.4)
        #expect(motion.pose(at: 0.6) == .rest)
    }

    @Test func reducedMotionAndHiddenWindowsStopWithoutShufflingOrRestarting() {
        for hidden in [false, true] {
            var motion = AppMarkMotion()
            motion.update(.init(hovered: true), at: 0) { _ in .orbit }
            motion.update(.init(hovered: true, reducedMotion: !hidden, visible: !hidden), at: 0.2)
            #expect(motion.playback == nil)
            #expect(motion.pose(at: 0.2) == .rest)
            #expect(motion.lastGesture == .orbit)
            motion.update(.init(reducedMotion: !hidden, visible: !hidden), at: 0.3)
            motion.update(.init(hovered: true, reducedMotion: !hidden, visible: !hidden), at: 0.4) { _ in
                Issue.record("Suppressed motion must not choose a gesture")
                return .bloom
            }
            motion.update(.init(hovered: true), at: 0.5)
            #expect(motion.playback == nil)
            #expect(motion.lastGesture == .orbit)
        }
    }

    @Test func bloomFormsBracketsAndACursorBeforeRebuilding() {
        let pose = AppMarkGesture.bloom.pose(at: 0.5, pointer: .zero)
        #expect(pose.dots[2].x == 0.5)
        #expect(pose.dots[2].y == 0.5)
        #expect(pose.dots[2].stretch == 3.9)
        #expect(pose.bracketsOpacity == 0.8)
        #expect(AppMarkGesture.bloom.pose(at: 1, pointer: .zero) == .rest)
    }
}
