import SwiftUI
import AppKit

// Playful main-window building blocks (spec 011). Decorative layers never take
// clicks or accessibility focus; every spontaneous motion respects the system
// "reduce motion" setting through PlayfulMotion.

extension Color {
    init(_ soft: SoftRGB) { self.init(red: soft.r, green: soft.g, blue: soft.b) }
    /// Soft cream used for large main-window surfaces instead of pure white.
    static let card = Color(PlayfulSurfaces.card)
    static let lemon = Color(red: 1, green: 0.94, blue: 0.68)
    static let lemonEdge = Color(red: 0.95, green: 0.70, blue: 0.20)
    static let blush = Color(red: 1, green: 0.87, blue: 0.92)
    static let blushEdge = Color(red: 0.91, green: 0.47, blue: 0.64)
    static let mintEdge = Color(red: 0.36, green: 0.72, blue: 0.52)
    static let skyDeep = Color(red: 0.30, green: 0.58, blue: 0.86)
    static let lilyPink = Color(red: 0.86, green: 0.42, blue: 0.68)
}

struct PlayfulTint {
    let fill: Color
    let edge: Color
    static let peach = PlayfulTint(fill: .peach, edge: .peachEdge)
    static let sky = PlayfulTint(fill: .sky, edge: .skyDeep)
    static let mint = PlayfulTint(fill: .mint, edge: .mintEdge)
    static let lilac = PlayfulTint(fill: .lilac, edge: .sage)
    static let blush = PlayfulTint(fill: .blush, edge: .blushEdge)
    static let lemon = PlayfulTint(fill: .lemon, edge: .lemonEdge)
    /// Order matches PlayfulPalette.count so badge colours stay stable.
    static let badges: [PlayfulTint] = [.peach, .sky, .mint, .lilac, .blush]
    static func badge(for id: String) -> PlayfulTint { badges[PlayfulPalette.index(for: id, count: badges.count)] }
    static let suggestions: [PlayfulTint] = [.peach, .sky, .mint]
}

extension OpeningPrompt {
    var playfulIcon: String {
        switch self { case .today: return "sun.max.fill"; case .story: return "book.fill"; case .question: return "moon.stars.fill"; case .picture: return "umbrella.fill" }
    }
    var tint: PlayfulTint {
        switch self { case .today: return .lemon; case .story: return .lilac; case .question: return .sky; case .picture: return .mint }
    }
}

let lilyGradient = LinearGradient(colors: [Color.sage, Color.lilyPink], startPoint: .topLeading, endPoint: .bottomTrailing)

struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .shadow(color: Color.ink.opacity(hovering ? 0.10 : 0), radius: 10, x: 0, y: 5)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

struct LilyPoseImage: View {
    var pose: StagePose = .idle
    var body: some View {
        if let image = PetCatalog.atlas("unicorn")?.frame(row: pose.row, column: pose.column) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else { BrandImage() }
    }
}

/// Static round avatar used in bubbles and the header. Never animates by itself.
struct LilyAvatar: View {
    var size: CGFloat = 34
    var pose: StagePose = .idle
    var body: some View {
        LilyPoseImage(pose: pose).padding(size * 0.06)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color.card, Color.lilac.opacity(0.7)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.lilacEdge, Color.peachEdge, Color.skyEdge], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1.5, size * 0.06)))
            .accessibilityHidden(true)
    }
}

/// Compact action chip under the child's voice bubble (重说 / 修改).
/// 重说 is the child's own action (filled warm coral); 修改 is a quieter outline chip.
struct VoiceFixChip: View {
    enum Emphasis { case primary, secondary }
    var title: String
    var symbol: String
    var emphasis: Emphasis = .secondary
    var action: () -> Void
    private static let coral = Color(red: 0.93, green: 0.52, blue: 0.38)
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(emphasis == .primary ? Color.white : Color.sage)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(emphasis == .primary ? AnyShapeStyle(LinearGradient(colors: [Color.peachEdge, Self.coral], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.card)))
            .overlay(Capsule().strokeBorder(emphasis == .primary ? Color.white.opacity(0.35) : Color.lilacEdge.opacity(0.7), lineWidth: 1))
            .contentShape(Capsule())
        }.buttonStyle(StoryButtonStyle()).hoverLift()
    }
}

struct ChildAvatar: View {
    var size: CGFloat = 30
    private static let portrait: NSImage? = Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Brand/child-avatar.png")) }
    var body: some View {
        if let portrait = Self.portrait {
            Image(nsImage: portrait).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.peachEdge, Color.lemonEdge], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1.5, size * 0.06)))
                .accessibilityHidden(true)
        } else { fallback }
    }
    private var fallback: some View {
        Image(systemName: "face.smiling.fill").font(.system(size: size * 0.62, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.80, blue: 0.30), Color(red: 0.98, green: 0.58, blue: 0.30)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            .shadow(color: Color.peachEdge.opacity(0.35), radius: 3, x: 0, y: 1.5)
            .accessibilityHidden(true)
    }
}

struct BouncingDots: View {
    var color: Color = .sage
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.6) {
                ForEach(0..<3) { index in
                    Circle().fill(color.opacity(0.4 + Double(index) * 0.2)).frame(width: size, height: size)
                        .offset(y: reduceMotion ? 0 : -abs(sin(time * 5 - Double(index) * 0.7)) * size * 0.8)
                }
            }.frame(height: size * 2, alignment: .bottom)
        }.accessibilityHidden(true)
    }
}

/// Replaces the bare system spinner while Lily is preparing a reply.
struct ThinkingBubble: View {
    var text: String
    var body: some View {
        HStack(spacing: 12) {
            LilyAvatar(size: 40, pose: .thinking)
            HStack(spacing: 10) {
                BouncingDots(color: .sage, size: 8)
                Text(text).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Color.quiet)
            }.padding(.horizontal, 16).padding(.vertical, 11)
                .background(Color.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.lilacEdge.opacity(0.45)))
                .shadow(color: Color.lilacEdge.opacity(0.18), radius: 6, x: 0, y: 3)
        }.padding(.vertical, 6).accessibilityElement(children: .combine).accessibilityLabel(text)
    }
}

/// Pops a freshly created bubble in once; older bubbles render immediately.
struct BubbleEntrance: ViewModifier {
    var isUser: Bool
    @State private var shown: Bool
    private let animate: Bool
    init(isUser: Bool, createdAt: Date, reduceMotion: Bool) {
        self.isUser = isUser
        let fresh = PlayfulMotion.bubbleEntrance(age: Date().timeIntervalSince(createdAt), reduceMotion: reduceMotion)
        animate = fresh
        _shown = State(initialValue: !fresh)
    }
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.9, anchor: isUser ? .bottomTrailing : .bottomLeading)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear { if animate && !shown { withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { shown = true } } }
    }
}

/// Soft dreamy sky behind the conversation: gradient, drifting clouds and a few
/// twinkling stars. Low contrast, no hit testing, frozen under reduced motion.
struct StorySkyBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Cloud { let x, y, scale, speed, opacity: Double }
    private struct Star { let x, y, size, rate, phase: Double; let color: Color }
    private static let clouds = [
        Cloud(x: 0.04, y: 0.10, scale: 1.0, speed: 7, opacity: 0.85),
        Cloud(x: 0.62, y: 0.05, scale: 0.75, speed: 5, opacity: 0.75),
        Cloud(x: 0.35, y: 0.30, scale: 0.6, speed: 4, opacity: 0.55),
        Cloud(x: 0.82, y: 0.48, scale: 0.9, speed: 6, opacity: 0.6),
        Cloud(x: 0.12, y: 0.66, scale: 0.7, speed: 3.5, opacity: 0.5)
    ]
    private static let stars = [
        Star(x: 0.06, y: 0.28, size: 9, rate: 1.3, phase: 0, color: .lemonEdge),
        Star(x: 0.93, y: 0.16, size: 11, rate: 1.0, phase: 1.2, color: .lilyPink),
        Star(x: 0.88, y: 0.72, size: 8, rate: 1.6, phase: 2.1, color: .skyDeep),
        Star(x: 0.10, y: 0.84, size: 10, rate: 1.1, phase: 0.6, color: .sage),
        Star(x: 0.50, y: 0.07, size: 7, rate: 1.8, phase: 2.8, color: .peachEdge),
        Star(x: 0.97, y: 0.42, size: 7, rate: 1.4, phase: 3.6, color: .lemonEdge),
        Star(x: 0.03, y: 0.52, size: 6, rate: 2.0, phase: 4.1, color: .lilyPink)
    ]
    private func sparkle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        var path = Path()
        let inner = radius * 0.36
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let r = index.isMultiple(of: 2) ? radius : inner
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(PlayfulSurfaces.skyTop), Color(PlayfulSurfaces.skyMiddle), Color(PlayfulSurfaces.skyBottom)], startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    for cloud in Self.clouds {
                        let span = size.width + 260
                        let x = (cloud.x * span + time * cloud.speed).truncatingRemainder(dividingBy: span) - 130
                        let y = cloud.y * size.height
                        let w = 150 * cloud.scale, h = 46 * cloud.scale
                        var puff = Path()
                        puff.addEllipse(in: CGRect(x: x, y: y, width: w, height: h))
                        puff.addEllipse(in: CGRect(x: x + w * 0.18, y: y - h * 0.45, width: w * 0.5, height: h * 1.05))
                        puff.addEllipse(in: CGRect(x: x + w * 0.45, y: y - h * 0.25, width: w * 0.42, height: h * 0.9))
                        context.fill(puff, with: .color(.white.opacity(cloud.opacity * PlayfulSurfaces.cloudOpacityScale)))
                    }
                    for star in Self.stars {
                        let twinkle = reduceMotion ? 0.55 : 0.25 + 0.5 * (sin(time * star.rate + star.phase) + 1) / 2
                        let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
                        context.fill(sparkle(center, star.size * (0.85 + twinkle * 0.3)), with: .color(star.color.opacity(twinkle * 0.55)))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The large Lily on the welcome / call stage. Reflects the real call state
/// first; a tap gives a short local wave with hearts and stars and nothing else
/// (no speech, message, call or network).
struct LilyStageView: View {
    var activity: StageActivity
    var level: Double = 0
    var halo: Color = .lilacEdge
    var size: CGFloat = 150
    /// Diagnostics only (`--verify-launch --sample-lily-cheer`): start one cheer so the capture shows it.
    var cheerOnAppear = false
    @State private var cheer = LilyCheer()
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func tap() { cheer.tap(at: Date()) }
    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1 / 30)) { timeline in
            let now = timeline.date
            let elapsed = now.timeIntervalSince(start)
            let progress = cheer.progress(at: now)
            let pose = LilyStage.pose(activity: activity, cheering: progress != nil, elapsed: elapsed, reduceMotion: reduceMotion)
            let lift = PlayfulMotion.floatOffset(elapsed: elapsed, reduceMotion: reduceMotion) + (activity == .idle ? PlayfulMotion.cheerHop(progress: progress, reduceMotion: reduceMotion) : 0)
            let haloScale = PlayfulMotion.haloScale(level: activity == .idle ? 0 : level, elapsed: elapsed, reduceMotion: reduceMotion)
            ZStack {
                Circle().fill(RadialGradient(colors: [halo.opacity(activity == .idle ? 0.34 : 0.5), halo.opacity(activity == .idle ? 0.10 : 0.2), halo.opacity(0)], center: .center, startRadius: size * 0.12, endRadius: size * 0.64))
                    .frame(width: size * 1.28, height: size * 1.28).scaleEffect(haloScale)
                if activity != .idle {
                    Circle().strokeBorder(halo.opacity(0.45), lineWidth: max(2, size * 0.018))
                        .frame(width: size * 1.08, height: size * 1.08).scaleEffect(haloScale)
                }
                StoryRainbow().frame(width: size * 1.2, height: size * 0.7).offset(y: -size * 0.16).opacity(0.5)
                Ellipse().fill(LinearGradient(colors: [Color.card, Color.lilac.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.92, height: size * 0.2)
                    .overlay(Ellipse().strokeBorder(Color.lilacEdge.opacity(0.4), lineWidth: 1))
                    .shadow(color: Color.lilacEdge.opacity(0.3), radius: 6, x: 0, y: 3)
                    .offset(y: size * 0.47)
                LilyPoseImage(pose: pose).frame(width: size, height: size)
                    .offset(y: CGFloat(lift))
                if let progress, activity == .idle {
                    let count = PlayfulMotion.particleCount(reduceMotion: reduceMotion)
                    ForEach(0..<count, id: \.self) { index in
                        CheerParticle(index: index, count: count, progress: progress, size: size)
                    }
                }
            }.frame(width: size * 1.3, height: size * 1.18)
        }
        .contentShape(Circle())
        .onTapGesture(perform: tap)
        .onAppear { if cheerOnAppear { tap() } }
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel("莉莉")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
    }
}

/// One heart or star floating out of a tap cheer.
struct CheerParticle: View {
    var index: Int
    var count: Int
    var progress: Double
    var size: CGFloat
    private static let colors: [Color] = [.blushEdge, .lemonEdge, .skyDeep, .lilyPink, .mintEdge, .peachEdge, .sage]
    var body: some View {
        let spread: Double = Double(index) - Double(count - 1) / 2
        let angle: Double = -Double.pi / 2 + spread * 0.42
        let distance: Double = Double(size) * (0.36 + progress * 0.42)
        let x = CGFloat(cos(angle) * distance)
        let y = CGFloat(sin(angle) * distance - progress * 18)
        let symbol = index.isMultiple(of: 2) ? "heart.fill" : "star.fill"
        let color: Color = Self.colors[index % Self.colors.count]
        return Image(systemName: symbol)
            .font(.system(size: size * 0.11, weight: .bold))
            .foregroundStyle(color)
            .scaleEffect(0.6 + progress * 0.6)
            .opacity(1 - progress)
            .offset(x: x, y: y)
    }
}

/// Speech-bubble greeting under the stage, tail pointing up at Lily.
struct GreetingBubble: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            if let subtitle { Text(subtitle).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(Color.quiet) }
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.lilacEdge.opacity(0.5), lineWidth: 1.2))
        .overlay(alignment: .top) {
            BubbleTail().fill(Color.card).overlay(BubbleTail().stroke(Color.lilacEdge.opacity(0.5), lineWidth: 1.2).mask(Rectangle().padding(.bottom, 1.5)))
                .frame(width: 22, height: 12).offset(y: -11)
        }
        .shadow(color: Color.lilacEdge.opacity(0.22), radius: 10, x: 0, y: 4)
    }
}
struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY * 0.6))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY * 0.6))
        return path
    }
}

extension CallVisualMode {
    var stageActivity: StageActivity {
        switch self { case .idle: return .idle; case .connecting: return .connecting; case .listening: return .listening; case .thinking: return .thinking; case .speaking: return .speaking; case .muted: return .muted }
    }
}

// MARK: 0.21.0 child-perspective additions

/// Small downscaled thumbnails for the sidebar; never decodes the full picture per render.
@MainActor enum ArtworkThumbnails {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(at url: URL, pixels: Int = 120) -> NSImage? {
        let key = "\(url.path)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Big primary action for children who cannot read or type yet.
struct WelcomeTalkButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button { model.toggleCall() } label: {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let glow = reduceMotion ? 0.5 : (sin(timeline.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(Color.sage)
                        .frame(width: 48, height: 48).background(Circle().fill(Color.card))
                    Text("和莉莉说话").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                }
                .padding(.leading, 10).padding(.trailing, 30).frame(height: 68)
                .background(Capsule().fill(lilyGradient))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
                .shadow(color: Color.sage.opacity(0.22 + glow * 0.2), radius: 8 + glow * 8, x: 0, y: 4)
            }
        }
        .buttonStyle(StoryButtonStyle()).hoverLift()
        .help("给莉莉打电话").accessibilityLabel("和莉莉说话，开始通话")
    }
}

/// Lily herself in the call panel: pose follows the real call state; colour ring and
/// status symbol keep the existing state language.
struct LilyCallBadge: View {
    var mode: CallVisualMode
    var level: Double = 0
    var size: CGFloat = 58
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let activity = mode.stageActivity
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || activity == .idle || activity == .muted)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let pose = LilyStage.pose(activity: activity, cheering: false, elapsed: elapsed, reduceMotion: reduceMotion)
            let lively = activity == .listening || activity == .speaking
            let pulse = lively && !reduceMotion ? PlayfulMotion.haloScale(level: level, elapsed: elapsed, reduceMotion: false) : 1
            ZStack {
                Circle().fill(mode.color.opacity(0.16)).scaleEffect(pulse * 1.06)
                LilyPoseImage(pose: pose).padding(size * 0.05)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.card))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(mode.color, lineWidth: 3))
                if activity == .connecting || activity == .thinking {
                    Circle().trim(from: 0.05, to: 0.6).stroke(mode.color.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: size + 8, height: size + 8)
                        .rotationEffect(.degrees(reduceMotion ? 0 : elapsed * 140))
                }
            }
            .frame(width: size + 12, height: size + 12)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: activity.badgeSymbol).font(.system(size: size * 0.2, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size * 0.38, height: size * 0.38).background(Circle().fill(mode.color))
                    .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
            }
        }.accessibilityElement().accessibilityLabel(mode.label)
    }
}

/// Waiting scene while Lily draws: colour blobs slowly bloom inside a little canvas.
struct PaintingBubble: View {
    var text: String
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let blobs: [(x: Double, y: Double, r: Double, color: Color, delay: Double)] = [
        (0.28, 0.40, 0.30, .peachEdge, 0), (0.70, 0.35, 0.26, .skyDeep, 0.12), (0.50, 0.70, 0.28, .mintEdge, 0.24),
        (0.20, 0.75, 0.18, .lilyPink, 0.36), (0.82, 0.72, 0.20, .lemonEdge, 0.48)
    ]
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LilyAvatar(size: 44, pose: .speaking)
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let fill = PaintingStatus.fill(elapsed: timeline.date.timeIntervalSince(start), reduceMotion: reduceMotion)
                Canvas { context, size in
                    for blob in Self.blobs {
                        let local = min(1, max(0, (fill - blob.delay) / (1 - blob.delay)))
                        guard local > 0 else { continue }
                        let radius = blob.r * Double(min(size.width, size.height)) * (0.3 + local * 0.9)
                        let rect = CGRect(x: blob.x * size.width - radius, y: blob.y * size.height - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(blob.color.opacity(0.55 * local + 0.15)))
                    }
                }
                .frame(width: 128, height: 88)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.card))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.peach.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.peachEdge.opacity(0.6), lineWidth: 1.5))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "paintbrush.pointed.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.lilyPink)
                        .rotationEffect(.degrees(reduceMotion ? 0 : sin(timeline.date.timeIntervalSinceReferenceDate * 3) * 12))
                        .offset(x: 8, y: 6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Color.quiet)
                BouncingDots(color: .lilyPink, size: 7)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.lilacEdge.opacity(0.45)))
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine).accessibilityLabel(text)
    }
}

/// One-time burst of stars and hearts around a picture that was just saved.
struct CelebrationBurst: View {
    let start: Date
    private static let colors: [Color] = [.lemonEdge, .lilyPink, .skyDeep, .mintEdge, .peachEdge, .sage]
    var body: some View {
        TimelineView(.explicit(PlayfulMotion.celebrationFrames(start:start))) { timeline in
            let progress = timeline.date.timeIntervalSince(start) / PlayfulMotion.celebrationDuration
            if progress < 1 {
                GeometryReader { geometry in
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let reach = Double(min(geometry.size.width, geometry.size.height)) * 0.55
                    ForEach(0..<PlayfulMotion.celebrationParticles, id: \.self) { index in
                        let angle = Double(index) / Double(PlayfulMotion.celebrationParticles) * 2 * .pi
                        let distance = reach * (0.3 + progress * 0.7)
                        Image(systemName: index.isMultiple(of: 3) ? "heart.fill" : "star.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Self.colors[index % Self.colors.count])
                            .scaleEffect(0.6 + progress * 0.7)
                            .opacity(1 - progress)
                            .position(x: center.x + CGFloat(cos(angle) * distance), y: center.y + CGFloat(sin(angle) * distance))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Diagnostics only (`--capture-playful-gallery`): time-dependent child-facing states in one still.
struct PlayfulGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PaintingBubble(text: "莉莉在画画…")
            HStack(spacing: 30) {
                ForEach([CallVisualMode.connecting, .listening, .thinking, .speaking, .muted], id: \.rawValue) { mode in
                    VStack(spacing: 10) { LilyCallBadge(mode: mode, level: 0.6, size: 58); Text(mode.label).font(.system(size: 14, weight: .semibold, design: .rounded)) }
                }
            }
            RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [.mint, .sky], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 300, height: 170).overlay(CelebrationBurst(start: Date().addingTimeInterval(-0.45)))
        }.padding(30).frame(width: 760, height: 560, alignment: .topLeading).foregroundStyle(Color.ink).background(StorySkyBackdrop())
    }
}
