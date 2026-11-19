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

struct ChildAvatar: View {
    var size: CGFloat = 30
    var body: some View {
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
