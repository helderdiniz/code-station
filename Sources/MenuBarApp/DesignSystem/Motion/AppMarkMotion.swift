import Foundation

enum AppMarkGesture: CaseIterable {
    case ripple, magnetic, orbit, bloom

    var duration: TimeInterval {
        switch self {
        case .ripple: 0.96
        case .magnetic: 0.3
        case .orbit: 1.2
        case .bloom: 1.4
        }
    }

    func pose(at progress: Double, pointer: CGPoint) -> AppMarkPose {
        let t = min(1, max(0, progress))
        guard t > 0, t < 1 || self == .magnetic else { return .rest }
        var pose = AppMarkPose.rest
        let wave = sin(.pi * t)
        switch self {
        case .ripple:
            for i in pose.dots.indices {
                let dx = pose.dots[i].x - AppMark.centres[2]
                let dy = pose.dots[i].y - AppMark.centres[0]
                let phase = (t - hypot(dx, dy) / 0.1638 * 0.075) / 0.4
                let pulse = phase > 0 && phase < 1 ? sin(phase * .pi) : 0
                pose.dots[i].radius *= 1 + pulse * (i == 2 ? 0.2 : 0.4)
                pose.dots[i].x += dx * 0.04 * pulse
                pose.dots[i].y += dy * 0.04 * pulse
                pose.dots[i].shade = pulse * 0.7
            }
            pose.scale += 0.025 * wave
            pose.ringRadius = 0.07 + 0.35 * Self.ease(t / 0.6)
            pose.ringOpacity = t < 0.6 ? sin(.pi * t / 0.6) * 0.19 : 0
        case .magnetic:
            let envelope = Self.ease(t)
            pose.tiltX = -pointer.y * 7 * envelope
            pose.tiltY = pointer.x * 9 * envelope
            pose.x = pointer.x * 0.005 * envelope
            pose.y = pointer.y * 0.005 * envelope
            pose.scale += 0.035 * envelope
            for i in pose.dots.indices {
                let depth = i == 2 ? 0.055 : 0.025 + Double(i % 3) * 0.0045
                pose.dots[i].x += pointer.x * depth * envelope
                pose.dots[i].y += pointer.y * depth * envelope
                pose.dots[i].shade = 0.15 * envelope
            }
        case .orbit:
            let angle = Self.smooth((t - 0.06) / 0.83) * .pi * 2
            let expand = 1 + 0.23 * wave
            for i in pose.dots.indices {
                let dx = pose.dots[i].x - AppMark.centres[1]
                let dy = pose.dots[i].y - AppMark.centres[1]
                pose.dots[i].x = AppMark.centres[1] + (dx * cos(angle) - dy * sin(angle)) * expand
                pose.dots[i].y = AppMark.centres[1] + (dx * sin(angle) + dy * cos(angle)) * expand
                pose.dots[i].radius *= 1 + 0.12 * wave
                pose.dots[i].shade = 0.35 * wave
            }
            pose.rotation = -5 * wave
            pose.scale += 0.04 * wave
        case .bloom:
            let envelope = t < 0.42 ? Self.ease((t - 0.09) / 0.33) : 1 - Self.smooth((t - 0.65) / 0.35)
            let targets = [(0.4, 0.29), (0.29, 0.43), (0.5, 0.5), (0.29, 0.57), (0.4, 0.71),
                           (0.6, 0.29), (0.71, 0.43), (0.71, 0.57), (0.6, 0.71)]
            for i in pose.dots.indices {
                pose.dots[i].x += (targets[i].0 - pose.dots[i].x) * envelope
                pose.dots[i].y += (targets[i].1 - pose.dots[i].y) * envelope
                pose.dots[i].radius += ((i == 2 ? 0.024 : 0.036) - pose.dots[i].radius) * envelope
                pose.dots[i].stretch = i == 2 ? 1 + 2.9 * envelope : 1
                pose.dots[i].shade = 0.65 * envelope
            }
            pose.bracketsOpacity = min(1, max(0, (envelope - 0.6) * 2.5)) * 0.8
            pose.scale += 0.045 * wave
            pose.rotation = 1.4 * wave
        }
        return pose
    }

    static func ease(_ progress: Double) -> Double {
        1 - pow(1 - min(1, max(0, progress)), 3)
    }

    private static func smooth(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

// All coordinates are fractions of the mark's drawing, including its original margin.
// Text and layout never enter the poses or the playback clock.
struct AppMarkPose: Equatable {
    struct Dot: Equatable {
        var x: Double
        var y: Double
        var radius: Double
        var stretch = 1.0
        var shade = 0.0
    }

    var dots: [Dot]
    var scale = 1.0
    var rotation = 0.0
    var tiltX = 0.0
    var tiltY = 0.0
    var x = 0.0
    var y = 0.0
    var ringRadius = 0.07
    var ringOpacity = 0.0
    var bracketsOpacity = 0.0

    static var rest: Self {
        Self(dots: (0..<9).map { i in
            Dot(x: AppMark.centres[i % 3], y: AppMark.centres[i / 3],
                radius: i == 2 ? AppMark.accentRadius : AppMark.dotRadius)
        })
    }

    func blended(to target: Self, by progress: Double) -> Self {
        if progress <= 0 { return self }
        if progress >= 1 { return target }
        var result = self
        for key in [\Self.scale, \.rotation, \.tiltX, \.tiltY, \.x, \.y,
                    \.ringRadius, \.ringOpacity, \.bracketsOpacity] {
            result[keyPath: key] += (target[keyPath: key] - self[keyPath: key]) * progress
        }
        for i in dots.indices {
            for key in [\Dot.x, \.y, \.radius, \.stretch, \.shade] {
                result.dots[i][keyPath: key] += (target.dots[i][keyPath: key] - dots[i][keyPath: key]) * progress
            }
        }
        return result
    }
}

struct AppMarkMotion {
    struct Input: Equatable {
        var hovered = false
        var focused = false
        var pointer = CGPoint(x: 0.6, y: -0.4)
        var reducedMotion = false
        var visible = true

        var active: Bool { hovered || focused }
    }

    struct Playback {
        let start: TimeInterval
        let duration: TimeInterval
        let from: AppMarkPose
        let gesture: AppMarkGesture?
        let pointer: CGPoint
        let target: AppMarkPose

        var finalPose: AppMarkPose { gesture?.pose(at: 1, pointer: pointer) ?? target }

        func pose(at time: TimeInterval) -> AppMarkPose {
            if time >= start + duration { return finalPose }
            let elapsed = max(0, time - start)
            if let gesture {
                let next = gesture.pose(at: elapsed / duration, pointer: pointer)
                return from.blended(to: next, by: AppMarkGesture.ease(elapsed / 0.11))
            }
            return from.blended(to: target, by: AppMarkGesture.ease(elapsed / duration))
        }
    }

    private(set) var input = Input()
    private(set) var lastGesture: AppMarkGesture?
    private(set) var playback: Playback?

    func pose(at time: TimeInterval) -> AppMarkPose { playback?.pose(at: time) ?? .rest }

    // A new input replaces the current flight. Sampling it first makes even a rapid
    // exit and re-entry continuous, without timers or queued completion callbacks.
    @discardableResult
    mutating func update(_ next: Input, at time: TimeInterval,
                         choose: ([AppMarkGesture]) -> AppMarkGesture = { $0.randomElement()! }) -> Bool {
        let previous = input
        input = next
        let from = pose(at: time)
        guard next.visible, !next.reducedMotion else {
            let changed = playback != nil
            playback = nil
            return changed
        }
        let entered = (next.hovered && !previous.hovered) || (next.focused && !previous.focused)
        if entered {
            let gesture = choose(AppMarkGesture.allCases.filter { $0 != lastGesture })
            lastGesture = gesture
            playback = Playback(start: time, duration: gesture.duration, from: from, gesture: gesture,
                                pointer: next.pointer, target: .rest)
            return true
        }
        if previous.active && !next.active {
            guard from != .rest else { playback = nil; return false }
            playback = Playback(start: time, duration: Motion.revealDuration, from: from, gesture: nil,
                                pointer: next.pointer, target: .rest)
            return true
        }
        if next.hovered, lastGesture == .magnetic, let playback,
           next.pointer != previous.pointer {
            let remainingEntry = playback.gesture == .magnetic ? playback.start + playback.duration - time : 0
            self.playback = Playback(start: time, duration: max(Motion.hoverDuration, remainingEntry), from: from, gesture: nil,
                                     pointer: next.pointer, target: AppMarkGesture.magnetic.pose(at: 1, pointer: next.pointer))
            return true
        }
        return false
    }

    mutating func stop() { playback = nil }
}
