import Foundation

enum PetBehavior: String, CaseIterable {
    case lookAround, readBook, stretch, sway, star, nap, greet, affection, landing

    static let everyday: [PetBehavior] = [.lookAround, .readBook, .stretch, .sway, .star]
    var duration: Double {
        switch self {
        case .lookAround: return 4.8
        case .readBook: return 7.2
        case .stretch: return 3.6
        case .sway: return 4.8
        case .star: return 5.6
        case .nap: return 12
        case .greet: return 2.4
        case .affection: return 3.2
        case .landing: return 0.8
        }
    }
    var caption: String {
        switch self {
        case .lookAround: return "看看周围"
        case .readBook: return "翻翻故事书"
        case .stretch: return "伸个懒腰"
        case .sway: return "轻轻摇一摇"
        case .star: return "追一颗小星星"
        case .nap: return "眯一小会儿"
        case .greet: return "你好呀"
        case .affection: return "摸摸，好开心"
        case .landing: return "站稳啦"
        }
    }
    var motion: PetMotion {
        switch self {
        case .lookAround: return .waiting
        case .readBook: return .reading
        case .stretch, .landing: return .jumping
        case .sway, .greet, .affection: return .waving
        case .star: return .working
        case .nap: return .idle
        }
    }
}

struct PetBehaviorContext {
    var baseMotion: PetMotion = .idle
    var engaged = false
    var interactive = true
    var visible = true
    var ambientEnabled = true
    var followsPointer = true
    var reducedMotion = false
    var pointerNear = false
    var blocked = false // An open popover/menu or a drag reserves the interaction area.
    var canPerform: Bool { interactive && visible && baseMotion == .idle && !engaged }
}

struct PetPerformance: Equatable {
    var motion: PetMotion = .idle
    var behavior: PetBehavior?
    var elapsed: Double = 0
    var caption: String? { behavior?.caption }
}

/// Local, monotonic-time scheduling. It never owns a conversation, audio device or window.
struct PetBehaviorDirector {
    private struct Activity {
        var behavior: PetBehavior
        var started: Double
        var automatic: Bool
    }
    private var active: Activity?
    private var nextAt: Double?
    private var lastTick: Double?
    private var lastInteraction: Double?
    private var lastGreeting = -Double.infinity
    private var lastAffection = -Double.infinity
    private var lastStar = -Double.infinity
    private var lastNap = -Double.infinity
    private var wasNear = false
    private var bag: [PetBehavior] = []
    private var previous: PetBehavior?
    private var randomState: UInt64

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) { randomState = seed }

    private mutating func random(_ lower: Double, _ upper: Double) -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return lower + Double(randomState >> 11) / Double(UInt64.max >> 11) * (upper - lower)
    }
    private mutating func rest(after now: Double) { nextAt = now + random(12, 22) }

    mutating func suspend(at now: Double) {
        active = nil; wasNear = false; lastTick = now; lastInteraction = now
        rest(after: now)
    }

    @discardableResult mutating func request(_ behavior: PetBehavior, at now: Double, context: PetBehaviorContext) -> Bool {
        guard context.canPerform else { return false }
        if behavior == .affection {
            guard now - lastAffection >= 4 else { return false }
            lastAffection = now
        }
        if behavior == .star {
            guard now - lastStar >= 6 else { return false }
            lastStar = now
        }
        active = Activity(behavior: behavior, started: now, automatic: false)
        lastInteraction = now; lastTick = now
        rest(after: now + behavior.duration)
        return true
    }

    mutating func advance(at now: Double, context: PetBehaviorContext) -> PetPerformance {
        if let lastTick, now < lastTick || now - lastTick > 5 { suspend(at: now) }
        lastTick = now
        if lastInteraction == nil { lastInteraction = now }
        if nextAt == nil { nextAt = now + random(5, 8) }
        guard context.canPerform else {
            suspend(at: now)
            return PetPerformance(motion: context.baseMotion)
        }
        if let activity = active, now >= activity.started + activity.behavior.duration { active = nil }
        if context.reducedMotion || !context.ambientEnabled || context.blocked {
            if active?.automatic == true { active = nil }
            rest(after: now)
        }
        let near = context.followsPointer && context.pointerNear && !context.reducedMotion
        if near && !wasNear && !context.blocked {
            lastInteraction = now
            if now - lastGreeting >= 30, active == nil || active?.behavior == .nap {
                lastGreeting = now
                active = Activity(behavior: .greet, started: now, automatic: false)
                rest(after: now + PetBehavior.greet.duration)
            }
        }
        wasNear = near
        if active == nil && context.ambientEnabled && !context.reducedMotion && !context.blocked && !near && now >= (nextAt ?? now) {
            let behavior: PetBehavior
            if now - (lastInteraction ?? now) >= 90 && now - lastNap >= 120 {
                behavior = .nap; lastNap = now
            } else {
                if bag.isEmpty {
                    bag = PetBehavior.everyday
                    for i in stride(from: bag.count - 1, through: 1, by: -1) {
                        bag.swapAt(i, min(i, Int(random(0, Double(i + 1)))))
                    }
                    if bag.last == previous { bag.swapAt(0, bag.count - 1) }
                }
                behavior = bag.removeLast()
            }
            if behavior != .nap { previous = behavior }
            active = Activity(behavior: behavior, started: now, automatic: true)
            rest(after: now + behavior.duration)
        }
        guard let active else { return PetPerformance() }
        return PetPerformance(motion: active.behavior.motion, behavior: active.behavior, elapsed: max(0, now - active.started))
    }
}

/// A stroke needs back-and-forth travel inside the pet, not a stationary cursor or a single pass.
struct PetStrokeTracker {
    private var lastX: Double?
    private var lastAt: Double = 0
    private var startAt: Double = 0
    private var travel: Double = 0
    private var direction = 0
    private var reversals = 0

    mutating func reset() { self = PetStrokeTracker() }
    mutating func move(x: Double, at now: Double, enabled: Bool) -> Bool {
        guard enabled else { reset(); return false }
        guard let previousX = lastX, now - lastAt < 0.45, now - startAt < 1.8 else {
            reset(); lastX = x; startAt = now; lastAt = now; return false
        }
        let dx = x - previousX
        guard abs(dx) < 90 else { reset(); return false }
        lastAt = now
        guard abs(dx) >= 3 else { return false }
        lastX = x; travel += abs(dx)
        let nextDirection = dx > 0 ? 1 : -1
        if direction != 0 && direction != nextDirection { reversals += 1 }
        direction = nextDirection
        if travel >= 85 && reversals >= 2 { reset(); return true }
        return false
    }
}

enum PetDecoration: String { case none, stars, hearts, sleep }
struct PetVisualFrame: Equatable {
    var pose = 0
    var offsetX = 0.0
    var offsetY = 0.0
    var rotation = 0.0
    var scaleX = 1.0
    var scaleY = 1.0
    var decoration = PetDecoration.none
    var decorationPhase = 0.0
    var decorationOpacity = 0.0
}

enum PetChoreography {
    static func frame(_ performance: PetPerformance, reducedMotion: Bool) -> PetVisualFrame {
        let elapsed = reducedMotion && performance.behavior != nil ? performance.behavior!.duration / 2 : max(0, performance.elapsed)
        guard let behavior = performance.behavior else {
            return PetVisualFrame(pose: PetAtlas.unicornPose(for: performance.motion, elapsed: elapsed, reducedMotion: reducedMotion))
        }
        let progress = min(1, elapsed / behavior.duration)
        let fadeIn = min(1, elapsed / 0.4), fadeOut = min(1, max(0, behavior.duration - elapsed) / 0.5)
        let envelope = fadeIn * fadeOut
        let arc = sin(progress * .pi)
        var frame = PetVisualFrame()
        switch behavior {
        case .lookAround:
            frame.pose = 2; frame.offsetX = sin(progress * 2 * .pi) * 4
            frame.rotation = sin(progress * 2 * .pi) * 4
        case .readBook:
            frame.pose = (1.9...2.15).contains(elapsed) || (5.1...5.35).contains(elapsed) ? 1 : 0
            frame.rotation = sin(progress * 4 * .pi) * 1.6
            frame.offsetY = -sin(progress * .pi) * 2
        case .stretch:
            frame.pose = 1; frame.scaleY = 1 + arc * 0.045; frame.scaleX = 1 - arc * 0.035
            frame.offsetY = arc * 4; frame.rotation = sin(progress * 2 * .pi) * 2
        case .sway:
            frame.pose = 1; frame.rotation = sin(progress * 4 * .pi) * 6
            frame.offsetX = sin(progress * 4 * .pi) * 3
        case .star:
            frame.pose = progress < 0.65 ? 2 : 5
            frame.offsetX = sin(progress * 2 * .pi) * 5
            frame.rotation = sin(progress * 2 * .pi) * 4
            frame.decoration = .stars
        case .nap:
            frame.pose = 1; frame.rotation = arc * -5; frame.offsetY = -arc * 3
            frame.scaleY = 1 - arc * 0.025; frame.decoration = .sleep
        case .greet:
            frame.pose = 5; frame.rotation = sin(progress * 4 * .pi) * 3
            frame.offsetY = abs(sin(progress * 2 * .pi)) * 3
        case .affection:
            frame.pose = 1; frame.rotation = sin(progress * 2 * .pi) * 4
            frame.scaleX = 1 + arc * 0.025; frame.scaleY = 1 - arc * 0.015
            frame.decoration = .hearts
        case .landing:
            frame.pose = 5; frame.offsetY = arc * 9
            frame.scaleX = 1 + sin(progress * 2 * .pi) * 0.025
            frame.scaleY = 1 - sin(progress * 2 * .pi) * 0.025
        }
        frame.offsetX *= envelope; frame.offsetY *= envelope; frame.rotation *= envelope
        frame.decorationOpacity = envelope
        frame.decorationPhase = progress
        if reducedMotion {
            frame.offsetX = 0; frame.offsetY = 0; frame.rotation = 0; frame.scaleX = 1; frame.scaleY = 1
            frame.decorationPhase = 0.5; frame.decorationOpacity = 1
        }
        return frame
    }
}
