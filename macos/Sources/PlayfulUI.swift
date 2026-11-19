import Foundation

// Pure decisions for the playful main window (spec 011). No SwiftUI, no side
// effects: nothing here speaks, sends, calls the network or touches AppModel.

/// Stable badge colour per conversation. Uses FNV-1a over UTF-8 so the result
/// never depends on Swift's per-process hash seed, list order or selection.
enum PlayfulPalette {
    static let count = 5
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
    static func index(for id: String, count: Int = PlayfulPalette.count) -> Int {
        guard count > 0 else { return 0 }
        return Int(fnv1a(id) % UInt64(count))
    }
}

/// What the stage Lily should reflect. Mirrors the real call state; `.idle`
/// means no call is shaping her pose.
enum StageActivity: Equatable, CaseIterable { case idle, connecting, listening, thinking, speaking, muted }

/// Poses in the bundled 3x2 unicorn atlas (see Companions/unicorn/manifest.json).
enum StagePose: Int, CaseIterable {
    case idle = 0, blink, listening, thinking, speaking, waving
    var row: Int { rawValue / 3 }
    var column: Int { rawValue % 3 }
}

/// A child's tap on the stage Lily: a short, finite wave with a cooldown so
/// rapid tapping cannot spam particles. Purely visual state.
struct LilyCheer: Equatable {
    static let duration: TimeInterval = 1.6
    static let cooldown: TimeInterval = 0.6
    private(set) var startedAt: Date?
    func progress(at now: Date) -> Double? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed < Self.duration else { return nil }
        return elapsed / Self.duration
    }
    func isActive(at now: Date) -> Bool { progress(at: now) != nil }
    /// Returns whether a new cheer began.
    @discardableResult mutating func tap(at now: Date) -> Bool {
        if let startedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed >= 0, elapsed < Self.duration + Self.cooldown { return false }
        }
        startedAt = now
        return true
    }
}

enum LilyStage {
    static let blinkPeriod: TimeInterval = 5.2
    static let blinkLength: TimeInterval = 0.22
    static let speakingBeat: TimeInterval = 0.45
    /// Real call state always wins over a tap; idle Lily blinks now and then
    /// unless the system asks for reduced motion.
    static func pose(activity: StageActivity, cheering: Bool, elapsed: TimeInterval, reduceMotion: Bool) -> StagePose {
        switch activity {
        case .connecting: return .waving
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return !reduceMotion && Int(max(0, elapsed) / speakingBeat) % 3 == 2 ? .idle : .speaking
        case .muted: return .idle
        case .idle: break
        }
        if cheering { return .waving }
        if !reduceMotion, max(0, elapsed).truncatingRemainder(dividingBy: blinkPeriod) > blinkPeriod - blinkLength { return .blink }
        return .idle
    }
}

/// Motion amplitudes. Every spontaneous movement is zero under reduced motion
/// and stays inside the view; nothing here moves a window.
enum PlayfulMotion {
    static let floatAmplitude: Double = 5
    static let floatPeriod: TimeInterval = 3.6
    static let maxHop: Double = 16
    static let maxHalo: Double = 1.12
    static let particles = 7
    static let entranceWindow: TimeInterval = 1.2
    static func floatOffset(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : sin(elapsed * 2 * .pi / floatPeriod) * floatAmplitude
    }
    /// Upward hop (negative y) that decays and lands by the end of the cheer.
    static func cheerHop(progress: Double?, reduceMotion: Bool) -> Double {
        guard let progress, !reduceMotion else { return 0 }
        let p = min(1, max(0, progress))
        return -abs(sin(p * .pi * 2)) * maxHop * (1 - p)
    }
    static func haloScale(level: Double, elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        let voice = min(1, max(0, level)).squareRoot() * 0.08
        let breath = (sin(elapsed * 2.2) + 1) / 2 * 0.03
        return min(maxHalo, 1 + voice + breath)
    }
    static func particleCount(reduceMotion: Bool) -> Int { reduceMotion ? 0 : particles }
    /// Only freshly created bubbles pop in; reopening older conversations does not replay.
    static func bubbleEntrance(age: TimeInterval, reduceMotion: Bool) -> Bool {
        !reduceMotion && age >= 0 && age < entranceWindow
    }
}

enum PlayfulGreeting {
    static func title(hour: Int, voice: Bool) -> String {
        if voice { return "莉莉在这里" }
        switch hour {
        case 5..<11: return "早上好，我是莉莉！"
        case 11..<18: return "下午好，我是莉莉！"
        default: return "晚上好，我是莉莉！"
        }
    }
    static func subtitle(voice: Bool) -> String? { voice ? nil : "今天想聊点什么？" }
}

/// sRGB colour with WCAG relative luminance, so "not too bright" is measurable.
struct SoftRGB: Equatable {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    var luminance: Double { 0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b) }
    static func contrast(_ a: SoftRGB, _ b: SoftRGB) -> Double {
        let (x, y) = (a.luminance, b.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// Main-window surfaces (0.20.1). Large areas stay soft cream / lavender instead
/// of pure white so the page does not glare; text keeps AAA contrast.
enum PlayfulSurfaces {
    static let maxBackdropLuminance = 0.85
    static let maxSurfaceLuminance = 0.93
    static let minTextContrast = 7.0
    static let ink = SoftRGB(0.25, 0.18, 0.35)
    static let skyTop = SoftRGB(0.945, 0.925, 0.94)
    static let skyMiddle = SoftRGB(0.925, 0.91, 0.955)
    static let skyBottom = SoftRGB(0.915, 0.925, 0.955)
    static let header = SoftRGB(0.94, 0.925, 0.95)
    static let sidebarTop = SoftRGB(0.915, 0.89, 0.965)
    static let sidebarMiddle = SoftRGB(0.94, 0.90, 0.925)
    static let sidebarBottom = SoftRGB(0.905, 0.915, 0.96)
    /// Lily bubble, composer, greeting, thinking pill, selected row, picture frame.
    static let card = SoftRGB(0.975, 0.962, 0.952)
    static let childBubble = SoftRGB(0.98, 0.89, 0.80)
    static let cloudOpacityScale = 0.55
    static var backdrops: [SoftRGB] { [skyTop, skyMiddle, skyBottom, header, sidebarTop, sidebarMiddle, sidebarBottom] }
    static var surfaces: [SoftRGB] { [card, childBubble] }
}
