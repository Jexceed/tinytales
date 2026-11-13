import Foundation
import AppKit
import ImageIO
import SwiftUI

struct PetChoice: Identifiable {
    var id: String
    var name: String
    var url: URL
}
enum PetCatalog {
    static func choices(resourceRoot: URL? = Bundle.main.resourceURL, userAssetsRoot: URL = AppResources.supportDirectory.appendingPathComponent("pets")) -> [PetChoice] {
        var result: [PetChoice] = []
        if let root = resourceRoot { result.append(PetChoice(id: "unicorn", name: "独角兽莉莉", url: root.appendingPathComponent("Companions/unicorn/poses.png"))) }
        let pets = userAssetsRoot.standardizedFileURL
        guard pets.path == pets.resolvingSymlinksInPath().path else { return result }
        for directory in (try? FileManager.default.contentsOfDirectory(at: pets, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("pet.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["spritesheetPath"] as? String, let name = manifest["displayName"] as? String else { continue }
            let image = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard image.path.hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: image.path) else { continue }
            result.append(PetChoice(id: "codex-local:\(directory.lastPathComponent)", name: "\(name) · 已导入", url: image))
        }
        return result
    }
    private static var cached: [String: PetAtlas] = [:]
    static func atlas(_ id: String) -> PetAtlas? {
        if let existing = cached[id] { return existing }
        if id == "unicorn", let root = Bundle.main.resourceURL, let atlas = try? PetAtlas(url: root.appendingPathComponent("Companions/unicorn/poses.png")) { cached[id] = atlas; return atlas }
        guard let choice = choices().first(where: { $0.id == id }) ?? choices().first,
              let atlas = try? PetAtlas(url: choice.url) else { return nil }
        cached[id] = atlas; return atlas
    }
}
enum PetMotion: String, CaseIterable {
    case idle, runningRight, runningLeft, waving, jumping, failed, waiting, working, reading
    var row: Int { switch self { case .idle: return 0; case .runningRight: return 1; case .runningLeft: return 2; case .waving: return 3; case .jumping: return 4; case .failed: return 5; case .waiting: return 6; case .working: return 7; case .reading: return 8 } }
    var count: Int { [6,8,8,4,5,8,6,6,6][row] }
    // Frame layout and duration data match the user's installed Codex renderer.
    var durations: [Double] {
        if self == .idle { return [280,110,110,140,140,320].map { $0 * 6 / 1000 } }
        let step: Double = [.runningRight: 120, .runningLeft: 120, .waving: 140, .jumping: 140, .failed: 140, .waiting: 150, .working: 120, .reading: 150][self] ?? 140
        let last: Double = [.runningRight: 220, .runningLeft: 220, .waving: 280, .jumping: 280, .failed: 240, .waiting: 260, .working: 220, .reading: 280][self] ?? 280
        return (0..<count).map { ($0 == count - 1 ? last : step) / 1000 }
    }
    func column(at seconds: Double, reducedMotion: Bool = false) -> Int {
        if reducedMotion { return 0 }
        let ds = durations; var remaining = max(0, seconds).truncatingRemainder(dividingBy: ds.reduce(0,+))
        for (i, duration) in ds.enumerated() { if remaining < duration { return i }; remaining -= duration }
        return 0
    }
    static func lookFrame(dx: Double, dy: Double) -> (row: Int, column: Int)? {
        let distance = hypot(dx,dy)
        guard distance > 32, distance < 420 else { return nil }
        let clockwise = (atan2(dx,dy) + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
        let sector = Int((clockwise / (2 * Double.pi) * 16).rounded()) % 16
        return (9 + sector / 8, sector % 8)
    }
    static func resolve(recording: Bool, busy: Bool, speaking: Bool, preparing: Bool, error: Bool) -> PetMotion {
        if recording { return .waiting }
        if busy || preparing { return .working }
        if speaking { return .reading }
        if error { return .failed }
        return .idle
    }
}
final class PetAtlas {
    let image: CGImage
    let rows: Int
    let illustrated: Bool
    var cellWidth: Int { illustrated ? 512 : 192 }
    var cellHeight: Int { illustrated ? 512 : 208 }
    private var frames: [Int: NSImage] = [:]
    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 1536, [1024,1872,2288].contains(image.height) else { throw PartnerError.message("这个桌宠的动画图集格式暂时不支持。") }
        self.image = image; illustrated = image.height == 1024; rows = image.height / (illustrated ? 512 : 208)
    }
    func frame(row: Int, column: Int) -> NSImage? {
        guard (0..<rows).contains(row), (0..<(illustrated ? 3 : 8)).contains(column) else { return nil }
        let key = row * 8 + column
        if let image = frames[key] { return image }
        guard let crop = image.cropping(to: CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)) else { return nil }
        let result = NSImage(cgImage: crop, size: NSSize(width: cellWidth, height: cellHeight)); frames[key] = result; return result
    }
    static func unicornPose(for state: PetMotion, elapsed: Double, reducedMotion: Bool) -> Int {
        switch state {
        case .idle: return !reducedMotion && elapsed.truncatingRemainder(dividingBy: 6.4) > 6.15 ? 1 : 0
        case .waiting: return 2
        case .working, .failed: return 3
        case .reading: return !reducedMotion && Int(elapsed / 0.55) % 3 == 2 ? 0 : 4
        case .waving, .jumping: return 5
        case .runningLeft, .runningRight: return 0
        }
    }
}
struct CompanionPortrait: NSViewRepresentable {
    var petID = "unicorn"
    func makeNSView(context: Context) -> PetCanvas { let canvas = PetCanvas(); canvas.atlas = PetCatalog.atlas(petID); canvas.interactive = false; return canvas }
    func updateNSView(_ view: PetCanvas, context: Context) { view.atlas = PetCatalog.atlas(petID) }
}

final class PetCanvas: NSView, NSMenuDelegate {
    var atlas: PetAtlas? { didSet { if oldValue !== atlas { renderedKey = -1; rendered = nil; tick() } } }
    var interactive = true { didSet { updateTrackingAreas() } }
    var followsPointer = true
    var ambientEnabled = true
    var animationsEnabled = true { didSet { if oldValue != animationsEnabled { configureClock() } } }
    var motion: () -> PetMotion = { .idle }
    var engaged: () -> Bool = { false }
    var interactionBlocked: () -> Bool = { false }
    var onClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onHide: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onAmbientToggle: (() -> Void)?
    var onCaptionChange: ((String?) -> Void)?
    private var clock: Timer?
    private var director = PetBehaviorDirector()
    private var stroke = PetStrokeTracker()
    private var tracking: NSTrackingArea?
    private var menuTracking = false
    private var state = PetMotion.idle
    private var stateStarted = ProcessInfo.processInfo.systemUptime
    private var renderedKey = -1
    private var rendered: NSImage?
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragged = false
    private var pendingClick: DispatchWorkItem?
    private var performance = PetPerformance()
    private var visual = PetVisualFrame()
    private var lastCaption: String?
    private var breath = 0.0
    private var gazeX = 0.0
    private var gazeY = 0.0
    private var previewing = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("莉莉桌宠")
        setAccessibilityHelp("单击聊天，双击打开对话。右键可以摸摸莉莉或一起玩星星。")
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var acceptsFirstResponder: Bool { interactive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }
    override func accessibilityPerformPress() -> Bool { guard interactive else { return false }; onClick?(); return true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureClock() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        if interactive {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
    }
    private func configureClock() {
        clock?.invalidate(); clock = nil; pendingClick?.cancel(); pendingClick = nil
        director.suspend(at: ProcessInfo.processInfo.systemUptime); stroke.reset()
        if window != nil && animationsEnabled && !previewing {
            clock = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(clock!, forMode: .common)
            tick()
        } else { updateCaption(nil) }
    }
    deinit { clock?.invalidate(); pendingClick?.cancel() }

    private func context() -> PetBehaviorContext {
        var near = false
        if let window {
            let center = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
            let mouse = NSEvent.mouseLocation
            near = hypot(mouse.x - center.x, mouse.y - center.y) < 150
        }
        return PetBehaviorContext(baseMotion: motion(), engaged: engaged(), interactive: interactive,
            visible: animationsEnabled && window?.isVisible == true && !isHiddenOrHasHiddenAncestor,
            ambientEnabled: ambientEnabled, followsPointer: followsPointer,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            pointerNear: near, blocked: interactionBlocked() || menuTracking || mouseStart != nil)
    }
    @discardableResult func perform(_ behavior: PetBehavior) -> Bool {
        let accepted = director.request(behavior, at: ProcessInfo.processInfo.systemUptime, context: context())
        tick(); return accepted
    }
    private func tick() {
        guard !previewing else { return }
        let now = ProcessInfo.processInfo.systemUptime, input = context()
        guard input.visible else { director.suspend(at: now); stroke.reset(); updateCaption(nil); return }
        var next = director.advance(at: now, context: input)
        if next.motion != state { state = next.motion; stateStarted = now }
        if next.behavior == nil { next.elapsed = now - stateStarted }
        render(next, reduced: input.reducedMotion, pointer: input.followsPointer && !input.blocked)
    }
    private func updateCaption(_ caption: String?) {
        if lastCaption != caption {
            lastCaption = caption; onCaptionChange?(caption)
            setAccessibilityLabel(caption.map { "莉莉，" + $0 } ?? "莉莉桌宠")
        }
    }
    private func render(_ next: PetPerformance, reduced: Bool, pointer: Bool) {
        performance = next
        var frame = PetChoreography.frame(next, reducedMotion: reduced)
        var row = next.motion.row, column = next.motion.column(at: next.elapsed, reducedMotion: reduced)
        var targetX = 0.0, targetY = 0.0
        if next.behavior == nil && next.motion == .idle && interactive && pointer && !reduced && !engaged(), let window {
            let center = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
            let mouse = NSEvent.mouseLocation, dx = mouse.x - center.x, dy = mouse.y - center.y
            if hypot(dx, dy) < 180 {
                frame.pose = 2; targetX = max(-2.5, min(2.5, dx / 55)); targetY = max(-1.5, min(1.5, dy / 80))
            }
            if atlas?.rows == 11, let look = PetMotion.lookFrame(dx: dx, dy: dy) { row = look.row; column = look.column }
        }
        if reduced || next.behavior != nil { gazeX = 0; gazeY = 0 }
        else { gazeX += (targetX - gazeX) * 0.16; gazeY += (targetY - gazeY) * 0.16 }
        frame.offsetX += gazeX; frame.offsetY += gazeY
        let nextBreath = reduced ? 0 : sin(next.elapsed * (next.behavior == .nap ? 1.1 : 1.8)) * 0.008
        if atlas?.illustrated == true { row = frame.pose / 3; column = frame.pose % 3 }
        let key = row * 8 + column
        if key != renderedKey || rendered == nil { renderedKey = key; rendered = atlas?.frame(row: row, column: column); needsDisplay = true }
        if visual != frame || (atlas?.illustrated == true && abs(nextBreath - breath) > 0.0001) { needsDisplay = true }
        visual = frame; breath = nextBreath
        updateCaption(next.caption)
    }
    /// Offline diagnostics use the production renderer with a frozen, explicit time.
    func showPreview(_ behavior: PetBehavior, elapsed: Double, reducedMotion: Bool = false) {
        previewing = true; clock?.invalidate(); clock = nil
        render(PetPerformance(motion: behavior.motion, behavior: behavior, elapsed: elapsed), reduced: reducedMotion, pointer: false)
    }
    var behaviorVerification: [String: Any] {
        ["behavior": performance.behavior?.rawValue ?? "idle", "caption": lastCaption ?? "找我聊天",
         "ambientEnabled": ambientEnabled, "followsPointer": followsPointer,
         "timerRunning": clock?.isValid == true, "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let rendered else { return }
        NSGraphicsContext.current?.imageInterpolation = atlas?.illustrated == true ? .high : .none
        let w = CGFloat(atlas?.cellWidth ?? 192), h = CGFloat(atlas?.cellHeight ?? 208)
        let scale = min(bounds.width / w, bounds.height / h) * (atlas?.illustrated == true ? (interactive ? 0.86 : 0.94) : 0.88)
        let breathe = atlas?.illustrated == true ? 1 + breath : 1
        let size = NSSize(width: w * scale * breathe, height: h * scale * breathe)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX + visual.offsetX, yBy: bounds.midY + visual.offsetY)
        transform.rotate(byDegrees: visual.rotation)
        transform.scaleX(by: visual.scaleX, yBy: visual.scaleY); transform.concat()
        rendered.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        drawDecoration()
    }
    private func drawDecoration() {
        guard visual.decoration != .none, visual.decorationOpacity > 0 else { return }
        let phase = visual.decorationPhase, unit = bounds.width / 174
        let color: NSColor = visual.decoration == .hearts
            ? NSColor(calibratedRed: 0.91, green: 0.43, blue: 0.60, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.28, alpha: 1)
        for index in 0..<3 {
            let p = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            var x = (index == 1 ? 148.0 : 21.0) + sin(p * .pi * 2) * 4
            var y = 101 + p * 42
            if visual.decoration == .stars { x = 87 + cos((phase + Double(index) / 5) * .pi * 2) * 67; y = 112 + sin((phase + Double(index) / 5) * .pi * 2) * 40 }
            let alpha = visual.decorationOpacity * (visual.decoration == .stars ? 0.85 : sin(p * .pi))
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: x * unit, yBy: y * unit); transform.scale(by: unit); transform.concat()
            if visual.decoration == .sleep {
                let text = index == 0 ? "z" : "Z"
                text.draw(at: NSPoint(x: -4, y: -4), withAttributes: [.font: NSFont.systemFont(ofSize: 10 + Double(index) * 2, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.56, green: 0.48, blue: 0.72, alpha: alpha)])
            } else {
                let path = NSBezierPath()
                if visual.decoration == .hearts {
                    path.move(to: NSPoint(x: 0, y: -5))
                    path.curve(to: NSPoint(x: -6, y: 3), controlPoint1: NSPoint(x: -3, y: -2), controlPoint2: NSPoint(x: -7, y: 0))
                    path.curve(to: NSPoint(x: 0, y: 4), controlPoint1: NSPoint(x: -6, y: 7), controlPoint2: NSPoint(x: -1, y: 8))
                    path.curve(to: NSPoint(x: 6, y: 3), controlPoint1: NSPoint(x: 1, y: 8), controlPoint2: NSPoint(x: 6, y: 7))
                    path.curve(to: NSPoint(x: 0, y: -5), controlPoint1: NSPoint(x: 7, y: 0), controlPoint2: NSPoint(x: 3, y: -2))
                } else {
                    for point in 0..<8 {
                        let angle = Double(point) * .pi / 4, radius = point % 2 == 0 ? 6.0 : 2.3
                        let p = NSPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                        if point == 0 { path.move(to: p) } else { path.line(to: p) }
                    }
                }
                path.close(); color.withAlphaComponent(alpha).setFill(); path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), input = context()
        let enabled = input.canPerform && input.followsPointer && !input.blocked && bounds.insetBy(dx: 28, dy: 20).contains(point)
        if stroke.move(x: point.x, at: ProcessInfo.processInfo.systemUptime, enabled: enabled) { perform(.affection) }
    }
    override func mouseExited(with event: NSEvent) { stroke.reset() }
    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        pendingClick?.cancel(); pendingClick = nil; stroke.reset()
        if event.clickCount == 2 { mouseStart = nil; windowStart = nil; dragged = false; onOpen?(); return }
        mouseStart = window?.convertPoint(toScreen: event.locationInWindow)
        windowStart = window?.frame.origin; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard interactive, let start = mouseStart, let origin = windowStart, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let dx = mouse.x - start.x, dy = mouse.y - start.y
        if hypot(dx, dy) > 4 {
            dragged = true; pendingClick?.cancel(); pendingClick = nil
            director.suspend(at: ProcessInfo.processInfo.systemUptime)
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard interactive else { return }
        let moved = dragged, hadPress = mouseStart != nil
        mouseStart = nil; windowStart = nil; dragged = false
        if moved, let window {
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) ?? NSScreen.main
            if let screen { let f = screen.visibleFrame; window.setFrameOrigin(NSPoint(x: min(max(window.frame.minX, f.minX), f.maxX - window.frame.width), y: min(max(window.frame.minY, f.minY), f.maxY - window.frame.height))) }
            onMove?(window.frame.origin); perform(.landing)
        } else if hadPress && event.clickCount < 2 {
            perform(.greet)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.animationsEnabled, self.window?.isVisible == true else { return }
                self.pendingClick = nil; self.onClick?()
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactive else { return nil }
        pendingClick?.cancel(); pendingClick = nil
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        for (title, action) in [("摸摸莉莉", #selector(petLily)), ("一起玩星星", #selector(playStar)), (ambientEnabled ? "安静陪伴" : "恢复小动作", #selector(toggleAmbient))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            if action != #selector(toggleAmbient) { item.isEnabled = context().canPerform }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("打开故事屋", #selector(openHouse)), ("和莉莉聊聊", #selector(quickChat)), ("隐藏桌宠", #selector(hidePet))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true; stroke.reset() }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    @objc private func petLily() { perform(.affection) }
    @objc private func playStar() { perform(.star) }
    @objc private func toggleAmbient() { onAmbientToggle?() }
    @objc private func openHouse() { onOpen?() }
    @objc private func quickChat() { onClick?() }
    @objc private func hidePet() { onHide?() }
}
