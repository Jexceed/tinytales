import AppKit

@MainActor func petBehaviorTestCases() -> [(String, @MainActor () async throws -> Void)] {
    func advance(_ director: inout PetBehaviorDirector, from: Double, to: Double, context: PetBehaviorContext = PetBehaviorContext()) -> PetPerformance {
        var result = PetPerformance()
        for t in stride(from: from, through: to, by: 0.25) { result = director.advance(at: t, context: context) }
        return result
    }
    return [
        ("PB-001 ambient life has varied nonrepeating routines and real rests", {
            var director = PetBehaviorDirector(seed: 7)
            var started: [(PetBehavior, Double)] = [], previous: PetBehavior?
            for t in stride(from: 0.0, through: 700, by: 0.25) {
                let behavior = director.advance(at: t, context: PetBehaviorContext()).behavior
                if let behavior, behavior != previous { started.append((behavior, t)) }
                previous = behavior
            }
            let everyday = started.map(\.0).filter { $0 != .nap }
            try expect(started.count >= 20, "idle life never developed")
            try expect(Set(everyday.prefix(5)) == Set(PetBehavior.everyday), "a routine repeated before all five were used")
            for i in 1..<started.count {
                try expect(started[i].0 != started[i-1].0, "adjacent routine repeated")
                try expect(started[i].1 - started[i-1].1 >= started[i-1].0.duration + 11.75, "no rest between routines")
            }
            try expect(started.filter { $0.0 == .nap }.allSatisfy { $0.1 >= 90 }, "pet napped on arrival")
            try expect(started.contains { $0.0 == .nap }, "long idle never permits a nap")
            for i in 1..<everyday.count { try expect(everyday[i] != everyday[i-1], "shuffle boundary repeated") }
        }),
        ("PB-002 hovering greets once and respects the approach preference and cooldown", {
            var director = PetBehaviorDirector(seed: 1), context = PetBehaviorContext()
            context.pointerNear = true; context.ambientEnabled = false
            try expect(director.advance(at: 0, context: context).behavior == .greet, "approach missing")
            try expect(advance(&director, from: 0.25, to: 4, context: context).behavior == nil, "stationary pointer kept greeting")
            context.pointerNear = false; _ = director.advance(at: 4.25, context: context)
            context.pointerNear = true
            try expect(director.advance(at: 4.5, context: context).behavior == nil, "pointer jitter bypassed cooldown")
            _ = advance(&director, from: 4.75, to: 31, context: context)
            context.pointerNear = false; _ = director.advance(at: 31.25, context: context)
            context.pointerNear = true; context.followsPointer = false
            try expect(director.advance(at: 31.5, context: context).behavior == nil, "disabled proximity still greeted")
            context.followsPointer = true
            try expect(director.advance(at: 31.75, context: context).behavior == .greet, "later approach never recovered")
        }),
        ("PB-002 petting requires back and forth movement and affection has a bounded cooldown", {
            var stroke = PetStrokeTracker()
            for i in 0..<30 { try expect(!stroke.move(x: 60, at: Double(i) / 30, enabled: true), "stationary hover counted as a stroke") }
            stroke.reset()
            for (i, x) in [40.0, 65, 90, 115].enumerated() { try expect(!stroke.move(x: x, at: Double(i) * 0.1, enabled: true), "one pass counted as petting") }
            try expect(!stroke.move(x: 80, at: 0.4, enabled: true), "one reversal counted as petting")
            try expect(stroke.move(x: 110, at: 0.5, enabled: true), "back and forth stroke not recognized")
            for (i, x) in [30.0, 70, 30, 70].enumerated() { try expect(!stroke.move(x: x, at: Double(i) * 0.1 + 1, enabled: false), "disabled strokes triggered") }
            var director = PetBehaviorDirector(seed: 1)
            let context = PetBehaviorContext(ambientEnabled: false)
            try expect(director.request(.affection, at: 2, context: context), "explicit petting rejected")
            try expect(!director.request(.affection, at: 2.1, context: context), "petting spam restarted the effect")
            try expect(advance(&director, from: 2.25, to: 6, context: context).behavior == nil, "affection never ended")
        }),
        ("PB-003 real activity and muted calls preempt all decoration without replay", {
            for motion in [PetMotion.waiting, .working, .reading, .failed] {
                var director = PetBehaviorDirector(seed: 1)
                try expect(director.request(.star, at: 0, context: PetBehaviorContext()), "fixture did not start")
                let context = PetBehaviorContext(baseMotion: motion)
                let output = director.advance(at: 0.25, context: context)
                try expect(output.motion == motion && output.behavior == nil, "decoration masked real status")
                try expect(!director.request(.affection, at: 0.5, context: context), "interaction overrode real status")
                try expect(director.advance(at: 0.75, context: PetBehaviorContext()).behavior == nil, "cancelled decoration revived")
            }
            var director = PetBehaviorDirector(seed: 1)
            let muted = PetBehaviorContext(engaged: true)
            try expect(!director.request(.star, at: 0, context: muted), "muted call accepted play")
            for t in 0..<200 { try expect(director.advance(at: Double(t), context: muted).behavior == nil, "muted call fell asleep") }
        }),
        ("PB-003 open chat menus and drag suppress spontaneous routines", {
            var director = PetBehaviorDirector(seed: 1)
            let blocked = PetBehaviorContext(pointerNear: true, blocked: true)
            for t in 0..<160 { try expect(director.advance(at: Double(t), context: blocked).behavior == nil, "open interaction started a routine") }
            try expect(director.advance(at: 160, context: PetBehaviorContext(pointerNear: true)).behavior == nil, "closing a menu invented a new approach")
            try expect(director.advance(at: 160.25, context: PetBehaviorContext()).behavior == nil, "closing chat caused a backlog")
        }),
        ("PB-004 quiet mode cancels ambient activity but preserves explicit play and stored preferences", {
            var director = PetBehaviorDirector(seed: 4)
            _ = advance(&director, from: 0, to: 8)
            let quiet = PetBehaviorContext(ambientEnabled: false)
            try expect(director.advance(at: 8.25, context: quiet).behavior == nil, "quiet mode left automatic motion alive")
            try expect(director.request(.star, at: 9, context: quiet), "quiet mode blocked a deliberate interaction")
            try expect(director.advance(at: 9.25, context: quiet).behavior == .star, "explicit play was immediately cancelled")
            let old = Data("{\"petFollowsPointer\":false,\"sessionMinutes\":15,\"speaks\":false}".utf8)
            var settings = try JSONDecoder().decode(PartnerSettings.self, from: old)
            try expect(settings.petAmbientEnabled && !settings.petFollowsPointer && settings.sessionMinutes == 15 && !settings.speaks, "migration lost existing choices")
            let store = try fixture(); defer { remove(store) }
            try store.setSettings(settings)
            let revision = store.revision
            settings.petAmbientEnabled = false
            try store.setSettings(settings)
            let restored = try store.settings()
            try expect(!restored.petAmbientEnabled && !restored.petFollowsPointer && !restored.speaks, "quiet preference did not persist")
            try expect(store.revision == revision, "visual preference reset conversation")
        }),
        ("PB-005 reduced motion suppresses autonomous behavior and freezes interaction geometry", {
            var director = PetBehaviorDirector(seed: 7)
            let reduced = PetBehaviorContext(reducedMotion: true, pointerNear: true)
            for t in 0..<180 { try expect(director.advance(at: Double(t), context: reduced).behavior == nil, "reduced motion still performed") }
            try expect(director.request(.affection, at: 180, context: reduced), "static feedback unavailable")
            for behavior in PetBehavior.allCases {
                for t in stride(from: 0.0, through: behavior.duration, by: 0.1) {
                    let frame = PetChoreography.frame(PetPerformance(motion: behavior.motion, behavior: behavior, elapsed: t), reducedMotion: true)
                    try expect(frame.offsetX == 0 && frame.offsetY == 0 && frame.rotation == 0 && frame.scaleX == 1 && frame.scaleY == 1 && frame.decorationPhase == 0.5, "reduced motion moved geometry or particles")
                    let reference = PetChoreography.frame(PetPerformance(motion: behavior.motion, behavior: behavior, elapsed: 0), reducedMotion: true)
                    try expect(frame == reference, "static feedback changed while reduced motion was enabled")
                }
            }
        }),
        ("PB-005 hiding sleep gaps and noninteractive portraits discard old routines", {
            for context in [PetBehaviorContext(visible: false), PetBehaviorContext(interactive: false)] {
                var director = PetBehaviorDirector(seed: 7)
                _ = director.request(.star, at: 0, context: PetBehaviorContext())
                try expect(director.advance(at: 0.25, context: context).behavior == nil, "hidden canvas performed")
                try expect(director.advance(at: 0.5, context: PetBehaviorContext()).behavior == nil, "showing replayed hidden work")
            }
            var director = PetBehaviorDirector(seed: 7)
            _ = director.request(.star, at: 0, context: PetBehaviorContext())
            try expect(director.advance(at: 600, context: PetBehaviorContext()).behavior == nil, "wake replayed stale motion")
            try expect(director.advance(at: 601, context: PetBehaviorContext()).behavior == nil, "wake skipped rest")
        }),
        ("PB-006 choreography stays within unicorn and generated imported atlases and returns smoothly to rest", {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("macos/Resources/Companions")
            let importedURL = try spriteAtlasFixture()
            defer { try? FileManager.default.removeItem(at: importedURL) }
            let unicorn = try PetAtlas(url: root.appendingPathComponent("unicorn/poses.png")), imported = try PetAtlas(url: importedURL)
            for behavior in PetBehavior.allCases {
                for t in stride(from: 0.0, through: behavior.duration + 0.1, by: 0.05) {
                    let performance = PetPerformance(motion: behavior.motion, behavior: behavior, elapsed: t)
                    let frame = PetChoreography.frame(performance, reducedMotion: false)
                    try expect(unicorn.frame(row: frame.pose / 3, column: frame.pose % 3) != nil, "unicorn pose missing")
                    try expect(imported.frame(row: behavior.motion.row, column: behavior.motion.column(at: t)) != nil, "imported frame missing")
                    try expect(abs(frame.offsetX) <= 5.01 && abs(frame.offsetY) <= 9.01 && abs(frame.rotation) <= 6.01 && (0.95...1.05).contains(frame.scaleY), "motion exceeded its bounds")
                }
                for t in [0, behavior.duration] {
                    let frame = PetChoreography.frame(PetPerformance(motion: behavior.motion, behavior: behavior, elapsed: t), reducedMotion: false)
                    try expect(abs(frame.offsetX) < 0.001 && abs(frame.offsetY) < 0.001 && abs(frame.rotation) < 0.001 && abs(frame.scaleX - 1) < 0.001 && abs(frame.scaleY - 1) < 0.001, "routine snapped at its endpoints")
                }
            }
        }),
        ("PB-007 native single double click drag and menus keep distinct actions", {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 210, height: 284), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let canvas = PetCanvas(frame: NSRect(x: 0, y: 0, width: 174, height: 174))
            canvas.followsPointer = false; canvas.ambientEnabled = false
            window.contentView = canvas; window.orderFront(nil)
            defer { canvas.animationsEnabled = false; window.orderOut(nil) }
            var clicks = 0, opens = 0, moves = 0, toggles = 0
            canvas.onClick = { clicks += 1 }; canvas.onOpen = { opens += 1 }; canvas.onMove = { _ in moves += 1 }; canvas.onAmbientToggle = { toggles += 1 }
            func event(_ type: NSEvent.EventType, _ count: Int = 1, x: Double = 70) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 80), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            }
            func settleClick() async { try? await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.12) * 1_000_000_000)) }
            canvas.mouseDown(with: event(.leftMouseDown)); canvas.mouseUp(with: event(.leftMouseUp)); await settleClick()
            try expect(clicks == 1 && opens == 0, "single click failed")
            canvas.mouseDown(with: event(.leftMouseDown)); canvas.mouseUp(with: event(.leftMouseUp))
            canvas.mouseDown(with: event(.leftMouseDown, 2)); canvas.mouseUp(with: event(.leftMouseUp, 2)); await settleClick()
            try expect(clicks == 1 && opens == 1, "double click also opened quick chat")
            canvas.mouseDown(with: event(.leftMouseDown)); canvas.mouseDragged(with: event(.leftMouseDragged, x: 100)); canvas.mouseUp(with: event(.leftMouseUp, x: 100)); await settleClick()
            try expect(moves == 1 && clicks == 1 && opens == 1, "drag triggered chat")
            let menu = canvas.menu(for: event(.rightMouseDown))!
            for title in ["摸摸莉莉", "一起玩星星", "恢复小动作"] {
                guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw PartnerError.message("TEST: missing pet menu item " + title) }
                _ = NSApp.sendAction(action, to: item.target, from: item)
            }
            try expect(clicks == 1 && opens == 1 && toggles == 1, "play menu sent a conversation action")
            try expect(canvas.behaviorVerification["caption"] as? String != nil, "behavior feedback unavailable")
            canvas.animationsEnabled = false
            try expect(canvas.behaviorVerification["timerRunning"] as? Bool == false, "hidden pet kept its timer")
        })
    ]
}
