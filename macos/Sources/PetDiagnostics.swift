import AppKit

/// Fixture-only captures: the same native canvas and assets used by the desktop pet.
@MainActor enum PetDiagnostics {
    static func capture(to directory: URL) throws -> [String: Any] {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix("/private/tmp/") || resolved.path.hasPrefix("/tmp/") else {
            throw PartnerError.message("桌宠诊断请写入 /tmp。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let atlas = PetCatalog.atlas("unicorn") else { throw PartnerError.message("莉莉图集未载入。") }
        func background(_ size: NSSize) -> NSView {
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor
            return view
        }
        func add(_ behavior: PetBehavior, elapsed: Double, to view: NSView, at point: NSPoint, reduced: Bool = false) {
            let canvas = PetCanvas(frame: NSRect(x: point.x + 23, y: point.y + 30, width: 174, height: 174))
            canvas.atlas = atlas; canvas.showPreview(behavior, elapsed: elapsed, reducedMotion: reduced)
            view.addSubview(canvas)
            let label = NSTextField(labelWithString: behavior.caption)
            label.font = NSFont.systemFont(ofSize: 15, weight: .medium); label.alignment = .center
            label.textColor = NSColor(calibratedRed: 0.32, green: 0.28, blue: 0.38, alpha: 1)
            label.frame = NSRect(x: point.x, y: point.y + 6, width: 220, height: 22); view.addSubview(label)
        }
        func save(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PartnerError.message("无法创建桌宠画布。") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PartnerError.message("无法保存桌宠画布。") }
            try png.write(to: directory.appendingPathComponent(name))
        }
        let gallery = background(NSSize(width: 660, height: 660))
        let strip = background(NSSize(width: 1100, height: 1980))
        for (i, behavior) in PetBehavior.allCases.enumerated() {
            add(behavior, elapsed: behavior.duration * 0.4, to: gallery, at: NSPoint(x: (i % 3) * 220, y: (2 - i / 3) * 220))
            for step in 0..<5 {
                add(behavior, elapsed: behavior.duration * Double(step) / 4, to: strip, at: NSPoint(x: step * 220, y: (8 - i) * 220))
            }
        }
        try save(gallery, "gallery.png"); try save(strip, "timing.png")
        let reduced = background(NSSize(width: 660, height: 220))
        for (i, t) in [0.0, 1.0, 2.0].enumerated() { add(.affection, elapsed: t, to: reduced, at: NSPoint(x: i * 220, y: 0), reduced: true) }
        try save(reduced, "reduced-motion.png")
        return ["success": true, "behaviors": PetBehavior.allCases.map(\.rawValue), "gallery": directory.appendingPathComponent("gallery.png").path,
                "timing": directory.appendingPathComponent("timing.png").path, "networkUsed": false, "microphoneOpened": false,
                "source": "production PetCanvas with fixed elapsed time"]
    }
}
