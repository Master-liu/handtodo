import AppKit

struct Note: Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var pigment: Data? = nil
    var detailedPigment: Data? = nil
    var sourcePigment: Data? = nil
    var sourceDetailedPigment: Data? = nil
    var sourceOffsetX: Double? = nil
    var sourceOffsetY: Double? = nil
    var writingAngle: Double? = nil
    var inkCoverage: Double? = nil
    var fontSize: Double? = Double(HandView.defaultFontSize)
    var done = false; var distance = 0.0; var reversals = 0
    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}
struct NoteRender {
    let bitmap: NSBitmapImageRep
    let pixelBounds: NSRect
    let sourceBounds: NSRect
    let detailedBounds: NSRect
}
struct HandWashBackup: Codable {
    let notes:[Note]
    let strokes:[PenStroke]
    let stickers:[PalmSticker]
}
struct PendingClick {
    let point: NSPoint
    let timestamp: TimeInterval
    var moved = false
}
struct SmudgeSnapshot {
    let index: Int
    let note: Note
    let pixels: Data
    let detailedPixels: Data?
    var sourcePixels: Data? = nil
    var sourceDetailedPixels: Data? = nil
    var changed = false
}
final class HandPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let view = contentView as? HandView, view.editor == nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            view.undoCurrent(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class WristButton: NSControl {
    var inkColor = NSColor(calibratedRed:0.31,green:0.20,blue:0.19,alpha:0.85) { didSet { needsDisplay=true } }
    private var pressed=false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        let font=NSFont(name:"HannotateSC-W5",size:18) ?? NSFont.systemFont(ofSize:18)
        let text=NSAttributedString(string:"涂鸦",attributes:[.font:font,.foregroundColor:inkColor.withAlphaComponent(pressed ? 1:0.88)])
        let size=text.size()
        NSGraphicsContext.saveGraphicsState()
        if let context=NSGraphicsContext.current?.cgContext {
            context.translateBy(x:bounds.midX,y:bounds.midY)
            context.rotate(by: -0.08)
            text.draw(at:NSPoint(x:-size.width/2,y:-size.height/2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event:NSEvent) { pressed=true; needsDisplay=true }
    override func mouseUp(with event:NSEvent) {
        let activate=pressed && bounds.contains(convert(event.locationInWindow,from:nil))
        pressed=false; needsDisplay=true
        if activate { _ = accessibilityPerformPress() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled,let action else { return false }
        return NSApp.sendAction(action,to:target,from:self)
    }
}
final class HandView: NSView, NSTextViewDelegate, NSMenuDelegate {
    static let defaultFontSize: CGFloat = 14
    static let eraserRadius: CGFloat = 8
    let hand = NSImage(contentsOf: Bundle.main.url(forResource: "hand", withExtension: "png")!)!
    let toolButton = WristButton(frame:NSRect(x:26,y:296,width:52,height:30))
    let mask: NSBitmapImageRep
    let surface = HandSurface.shared
    var washBackup:HandWashBackup?
    var stickerStore:StickerStore!
    var stickerMenuOpen=false
    var stickerMode=false
    var stickerDragPoint:NSPoint?
    var stickerDragRecorded=false
    var displayedStickers=HandView.blank()
    var drawingStore: DrawingStore!
    var penMode = false
    var drawingEraserMode = false
    var penColor: PenColor = .black
    var displayedDrawing = HandView.blank()
    var displayedInk = HandView.blank()
    var ink: NSBitmapImageRep
    var notes: [Note] = []
    var layers: [NSBitmapImageRep] = []
    var detailedLayers: [NSBitmapImageRep?] = []
    var sourceLayers: [NSBitmapImageRep?] = []
    var sourceDetailedLayers: [NSBitmapImageRep?] = []
    private var noteRenders: [NoteRender?] = []
    var selected: Int?
    var moving = false
    var editor: NSTextView?
    var last: NSPoint?
    var pointerHeld = false
    var pendingClick: PendingClick?
    var active: Int?
    var smudgeHistory: [SmudgeSnapshot] = []
    var pendingSmudge: SmudgeSnapshot?
    var direction: CGFloat = 0
    var eraserPoint: NSPoint?
    var interacting: Bool { editor != nil || pointerHeld }
    let folder: URL
    override var isFlipped: Bool { true }
    static func blank(scale: Int = 1) -> NSBitmapImageRep {
        blank(size: NSSize(width: 640, height: 427), scale: scale)
    }
    static func blank(size: NSSize, scale: Int) -> NSBitmapImageRep {
        let width = Int(ceil(size.width))*scale, height = Int(ceil(size.height))*scale
        let b = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width*4, bitsPerPixel: 32)!
        b.size = NSSize(width: width/scale, height: height/scale)
        b.bitmapData!.initialize(repeating: 0, count: b.bytesPerRow * b.pixelsHigh)
        return b
    }
    init(storage: URL? = nil) {
        folder = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HandTodo")
        mask = NSBitmapImageRep(data: hand.tiffRepresentation!)!
        ink = Self.blank()
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 427))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("notes.json")), let saved = try? JSONDecoder().decode([Note].self, from: data), let png = try? Data(contentsOf: folder.appendingPathComponent("ink.png")), let bitmap = NSBitmapImageRep(data: png) {
            notes = saved
            // Normalize restored PNG into the exact working pixel format.
            let context = NSGraphicsContext(bitmapImageRep: ink)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            bitmap.draw(in: NSRect(x: 0, y: 0, width: 640, height: 427))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let data=try? Data(contentsOf:folder.appendingPathComponent("wash-backup.json")) { washBackup=try? JSONDecoder().decode(HandWashBackup.self,from:data) }
        stickerStore=StickerStore(folder:folder)
        refreshStickers()
        drawingStore = DrawingStore(folder:folder)
        refreshDrawing()
        restoreLayers()
        toolButton.setAccessibilityRole(.button)
        toolButton.setAccessibilityLabel("涂鸦")
        toolButton.toolTip = "画笔颜色与待办模式"
        addSubview(toolButton)
    }
    func detailedBitmap(_ data: Data?) -> NSBitmapImageRep? {
        guard let data, let image = NSBitmapImageRep(data: data), image.pixelsWide == 1280, image.pixelsHigh == 854 else { return nil }
        let result = Self.blank(scale: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
    func restoreLayers() {
        sourceLayers = notes.map { sourceBitmap($0.sourcePigment, scale: 1) }
        sourceDetailedLayers = notes.map { sourceBitmap($0.sourceDetailedPigment, scale: 2) }
        detailedLayers = notes.map { detailedBitmap($0.detailedPigment) }
        layers = notes.map { note in
            let layer = Self.blank()
            if let data = note.pigment, let image = NSBitmapImageRep(data: data) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
                image.draw(in: bounds); NSGraphicsContext.restoreGraphicsState()
            }
            return layer
        }
        // Older versions stored one flattened image. Assign its pixels once to the nearest note.
        let legacy = notes.indices.filter { notes[$0].pigment == nil }
        if !legacy.isEmpty {
            for y in 0..<427 { for x in 0..<640 {
                let offset = y*ink.bytesPerRow+x*4
                guard ink.bitmapData![offset+3] > 0 else { continue }
                let nearest = notes.indices.min { a, b in
                    func distance(_ i: Int) -> Double {
                        let r = notes[i].rect
                        return pow(max(r.minX-Double(x), 0, Double(x)-r.maxX), 2) + pow(max(r.minY-Double(y), 0, Double(y)-r.maxY), 2)
                    }
                    return distance(a) < distance(b)
                }
                if let i = nearest, notes[i].pigment == nil {
                    for c in 0..<4 { layers[i].bitmapData![offset+c] = ink.bitmapData![offset+c] }
                }
            } }
        }
        for i in notes.indices where notes[i].fontSize == nil {
            let scaled = Self.blank(), context = NSGraphicsContext(bitmapImageRep: scaled)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let anchor = NSPoint(x:notes[i].x,y:427-notes[i].y)
            context.cgContext.translateBy(x:anchor.x,y:anchor.y)
            context.cgContext.scaleBy(x:0.8,y:0.8)
            context.cgContext.translateBy(x:-anchor.x,y:-anchor.y)
            layers[i].draw(in:bounds)
            NSGraphicsContext.restoreGraphicsState()
            layers[i] = scaled; notes[i].width *= 0.8; notes[i].height *= 0.8; notes[i].fontSize = 16
        }
        rebuildInk()
    }
    private func sourceBitmap(_ data: Data?, scale: Int) -> NSBitmapImageRep? {
        guard let data, let image = NSBitmapImageRep(data: data) else { return nil }
        let result = Self.blank(size: NSSize(width: image.pixelsWide/scale, height: image.pixelsHigh/scale), scale: scale)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        image.draw(in: NSRect(origin: .zero, size: result.size))
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
    func sourceOrigin(_ note: Note) -> NSPoint {
        NSPoint(x: note.x+(note.sourceOffsetX ?? 0), y: note.y+(note.sourceOffsetY ?? 0))
    }
    private func projectSource(_ source: NSBitmapImageRep, note: Note, scale: Int) -> NSBitmapImageRep {
        let result = Self.blank(scale: scale), origin = sourceOrigin(note)
        let dx = Int((origin.x*Double(scale)).rounded()), dy = Int((origin.y*Double(scale)).rounded())
        let left = max(0, -dx), right = min(source.pixelsWide, result.pixelsWide-dx)
        let top = max(0, -dy), bottom = min(source.pixelsHigh, result.pixelsHigh-dy)
        guard left < right, top < bottom else { return result }
        for y in top..<bottom {
            result.bitmapData!.advanced(by: (y+dy)*result.bytesPerRow+(left+dx)*4).update(from: source.bitmapData!.advanced(by: y*source.bytesPerRow+left*4), count: (right-left)*4)
        }
        return result
    }
    func noteAnchor(_ note: Note) -> NSPoint { NSPoint(x: note.x, y: note.y) }
    func noteAngle(_ note: Note) -> Double { note.writingAngle ?? surface.writingAngle(at: noteAnchor(note)) }
    func notePoint(_ p: NSPoint, note: Note) -> NSPoint {
        surface.orient(p, anchor: noteAnchor(note), angle: noteAngle(note))
    }
    func pointInNote(_ p: NSPoint, note: Note) -> NSPoint {
        surface.unorient(p, anchor: noteAnchor(note), angle: noteAngle(note))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if toolButton.frame.contains(point) { return toolButton }
        if let field = editor as? SurfaceTextView {
            let p = surface.unorient(surface.canonical(point), anchor: field.anchor, angle: field.angle)
            return field.editingContains(p) ? field : self
        }
        return super.hitTest(point)
    }
    func rebuildInk(changedIndex: Int? = nil) {
        if let i = changedIndex, noteRenders.count == layers.count { noteRenders[i] = nil }
        else { noteRenders = Array(repeating:nil,count:layers.count) }
        ink = Self.blank()
        displayedInk = Self.blank(scale: 2)
        for i in layers.indices {
            if noteRenders[i] == nil {
                let sourceBounds = HandSurface.inkBounds(layers[i])
                let sourceLayer: NSBitmapImageRep
                if let detail = detailedLayers[i] { sourceLayer = detail }
                else {
                    sourceLayer = Self.blank(scale: 2)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sourceLayer)
                    layers[i].draw(in:bounds)
                    NSGraphicsContext.restoreGraphicsState()
                }
                let detailedBounds = HandSurface.inkBounds(sourceLayer)
                let anchor = noteAnchor(notes[i]), angle = noteAngle(notes[i])
                let bitmap = surface.warpDetailed(sourceLayer,anchor:anchor,angle:angle,sourceBounds:detailedBounds)
                noteRenders[i] = NoteRender(bitmap:bitmap,pixelBounds:surface.displayBounds(detailedBounds,anchor:anchor,angle:angle,scale:2),sourceBounds:sourceBounds,detailedBounds:detailedBounds)
            }
            let rendered = noteRenders[i]!
            composite(layers[i],into:ink,pixelBounds:rendered.sourceBounds)
            composite(rendered.bitmap,into:displayedInk,pixelBounds:rendered.pixelBounds)
        }
    }
    private func composite(_ source: NSBitmapImageRep, into target: NSBitmapImageRep, pixelBounds: NSRect) {
        guard !pixelBounds.isEmpty else { return }
        let src = source.bitmapData!, dest = target.bitmapData!
        for y in Int(pixelBounds.minY)..<Int(ceil(pixelBounds.maxY)) {
            for x in Int(pixelBounds.minX)..<Int(ceil(pixelBounds.maxX)) {
                let offset = y*source.bytesPerRow+x*4, alpha = Double(src[offset+3])/255
                if alpha == 0 { continue }
                for c in 0..<4 { dest[offset+c] = UInt8(min(255,(Double(src[offset+c])+Double(dest[offset+c])*(1-alpha)).rounded())) }
            }
        }
    }
    @discardableResult func moveNote(_ i: Int, dx: Int, dy: Int) -> Bool {
        guard !notes[i].done, dx != 0 || dy != 0 else { return false }
        // Retain the original canvas of legacy notes before their first move.
        if sourceLayers[i] == nil {
            sourceLayers[i] = sourceBitmap(layers[i].representation(using:.png,properties:[:]),scale:1)
            sourceDetailedLayers[i] = sourceBitmap(detailedLayers[i]?.representation(using:.png,properties:[:]),scale:2)
            notes[i].sourceOffsetX = -notes[i].x; notes[i].sourceOffsetY = -notes[i].y
        }
        var proposed = notes[i]; proposed.x += Double(dx); proposed.y += Double(dy)
        // Once the first line is outside the hand, keep its last writing direction
        // so later lines can be brought back without rotating around a remote anchor.
        proposed.writingAngle = onSkin(surface.display(noteAnchor(proposed))) ? surface.writingAngle(at:noteAnchor(proposed)) : noteAngle(notes[i])
        let moved = projectSource(sourceLayers[i]!, note: proposed, scale: 1)
        let region = HandSurface.inkBounds(moved)
        var visible = false
        if !region.isEmpty {
            outer: for y in Int(region.minY)..<Int(ceil(region.maxY)) { for x in Int(region.minX)..<Int(ceil(region.maxX)) {
                if moved.bitmapData![y*moved.bytesPerRow+x*4+3] > 0 && onSkin(surface.display(notePoint(NSPoint(x:x,y:y),note:proposed))) { visible = true; break outer }
            } }
        }
        guard visible else { return false }
        smudgeHistory.removeAll { $0.index == i }
        if let detail = sourceDetailedLayers[i] {
            detailedLayers[i] = projectSource(detail, note: proposed, scale: 2)
        }
        layers[i] = moved; notes[i] = proposed
        rebuildInk(changedIndex:i); needsDisplay = true; return true
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z" { undoCurrent(); return }
        if stickerMode && (event.keyCode == 51 || event.keyCode == 117) { deleteSticker();return }
        if event.keyCode == 53 { stickerStore.selected=nil; selected = nil; needsDisplay = true } else { super.keyDown(with: event) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func save() {
        drawingStore.save(); stickerStore.save()
        for i in notes.indices {
            notes[i].pigment = layers[i].representation(using: .png, properties: [:])
            notes[i].detailedPigment = detailedLayers[i]?.representation(using: .png, properties: [:])
            notes[i].sourcePigment = sourceLayers[i]?.representation(using: .png, properties: [:])
            notes[i].sourceDetailedPigment = sourceDetailedLayers[i]?.representation(using: .png, properties: [:])
        }
        if let data = ink.representation(using: .png, properties: [:]) { try? data.write(to: folder.appendingPathComponent("ink.png"), options: .atomic) }
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: folder.appendingPathComponent("notes.json"), options: .atomic) }
    }
    override func draw(_ dirtyRect: NSRect) {
        hand.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation:NSImageInterpolation.high.rawValue])
        let image = NSImage(size: bounds.size); image.addRepresentation(displayedInk)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let art = NSImage(size:bounds.size); art.addRepresentation(displayedDrawing)
        art.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        let stickers=NSImage(size:bounds.size);stickers.addRepresentation(displayedStickers)
        stickers.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        (editor as? SurfaceTextView)?.drawOnHand()
        if let point = eraserPoint, !moving, !stickerMode, (penMode && drawingEraserMode || !penMode && active != nil) {
            let ring = NSBezierPath()
            for step in 0...32 {
                let angle = Double(step)*2 * .pi/32
                let local = NSPoint(x:point.x+cos(angle)*Self.eraserRadius,y:point.y+sin(angle)*Self.eraserRadius)
                let oriented = penMode ? local : notePoint(local,note:notes[active!])
                let p = surface.display(oriented)
                if step == 0 { ring.move(to:p) } else { ring.line(to:p) }
            }
            ring.close()
            NSColor.black.withAlphaComponent(0.25).setStroke();ring.lineWidth=2;ring.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke();ring.lineWidth=1;ring.stroke()
        }
    }
    func onSkin(_ p: NSPoint) -> Bool {
        guard bounds.contains(p) else { return false }
        let x = min(639,max(0,Int(p.x))), y = min(426,max(0,Int(p.y)))
        return surface.skin[y*640+x]
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func inkContains(_ p: NSPoint, index: Int) -> Bool {
        let local = pointInNote(p,note:notes[index]), bitmap = layers[index]
        guard notes[index].rect.insetBy(dx:-5,dy:-5).contains(local) else { return false }
        let cx = Int(local.x), cy = Int(local.y)
        for y in max(0,cy-5)...min(426,max(0,cy+5)) { for x in max(0,cx-5)...min(639,max(0,cx+5)) {
            if bitmap.bitmapData![y*bitmap.bytesPerRow+x*4+3] > 32 { return true }
        } }
        return false
    }

    static func segmentDistanceSquared(_ point: NSPoint, from start: NSPoint, to end: NSPoint) -> Double {
        let dx = end.x-start.x, dy = end.y-start.y, length = dx*dx+dy*dy
        let t = length > 0 ? max(0,min(1,((point.x-start.x)*dx+(point.y-start.y)*dy)/length)) : 0
        let x = point.x-start.x-t*dx, y = point.y-start.y-t*dy
        return x*x+y*y
    }
    private func eraserBounds(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(x:min(start.x,end.x)-Self.eraserRadius,y:min(start.y,end.y)-Self.eraserRadius,width:abs(end.x-start.x)+2*Self.eraserRadius,height:abs(end.y-start.y)+2*Self.eraserRadius).intersection(bounds)
    }
    func eraserTouches(from start: NSPoint, to end: NSPoint, index: Int) -> Bool {
        let a = pointInNote(start,note:notes[index]), b = pointInNote(end,note:notes[index])
        let cached = noteRenders.count == layers.count ? noteRenders[index]?.sourceBounds : nil
        let region = eraserBounds(from:a,to:b).intersection(cached ?? HandSurface.inkBounds(layers[index]))
        guard !region.isEmpty else { return false }
        let bitmap = layers[index], pixels = bitmap.bitmapData!
        for y in Int(floor(region.minY))..<Int(ceil(region.maxY)) { for x in Int(floor(region.minX))..<Int(ceil(region.maxX)) {
            if pixels[y*bitmap.bytesPerRow+x*4+3] > 0 && Self.segmentDistanceSquared(NSPoint(x:x,y:y),from:a,to:b) < Self.eraserRadius*Self.eraserRadius { return true }
        } }
        return false
    }
    static func coverage(_ bitmap: NSBitmapImageRep) -> Double {
        let pixels = bitmap.bitmapData!
        var total = 0.0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide { total += Double(pixels[y*bitmap.bytesPerRow+x*4+3])/255 } }
        return total
    }
    override func mouseDown(with event: NSEvent) {
        let displayPoint = convert(event.locationInWindow, from: nil)
        let p = surface.canonical(displayPoint)
        if editor != nil { commit() }
        pendingClick = nil; pointerHeld = false; eraserPoint = nil
        guard onSkin(displayPoint) else { return }
        pointerHeld = true
        if stickerMode {
            stickerStore.selected=stickerStore.hit(p)
            stickerDragPoint=p;stickerDragRecorded=false
            window?.makeKey();window?.makeFirstResponder(self);return
        }
        if penMode {
            window?.makeKey();window?.makeFirstResponder(self)
            if drawingEraserMode { eraserPoint=p;drawingStore.beginErasing(p) }
            else { drawingStore.begin(p,color:penColor) }
            refreshDrawing();return
        }
        let wantsMove = event.modifierFlags.contains(.option)
        if let i = notes.indices.reversed().first(where: { !notes[$0].done && (wantsMove ? inkContains(p,index:$0) : eraserTouches(from:p,to:p,index:$0)) }) {
            if notes[i].done { return }
            moving = event.modifierFlags.contains(.option)
            selected = i
            window?.makeKey(); window?.makeFirstResponder(self)
            active = i; last = moving ? p : pointInNote(p, note: notes[i]); direction = 0
            eraserPoint = moving ? nil : last; needsDisplay = true; return
        }
        selected = nil; needsDisplay = true
        if !event.modifierFlags.contains(.option) { pendingClick = PendingClick(point:displayPoint,timestamp:event.timestamp) }
    }
    func refreshStickers() { displayedStickers=surface.warpDetailed(stickerStore.bitmap());needsDisplay=true }
    func addSticker(_ asset:String) {
        setPen(nil);stickerMode=true;stickerStore.add(asset);refreshStickers()
    }
    func enableStickers() { setPen(nil);stickerMode=true }
    override func scrollWheel(with event:NSEvent) {
        guard stickerMode else { super.scrollWheel(with:event);return }
        let p=surface.canonical(convert(event.locationInWindow,from:nil))
        if let hit=stickerStore.hit(p) { stickerStore.selected=hit }
        let delta=event.scrollingDeltaY
        if event.modifierFlags.contains(.option) { changeSticker(angle:Double(delta)*0.035) }
        else { changeSticker(factor:exp(max(-0.3,min(0.3,Double(delta)*0.025)))) }
    }
    func changeSticker(factor:Double=1,angle:Double=0) {
        _=stickerStore.transform(factor:factor,angle:angle,valid:{self.onSkin(self.surface.display($0))});refreshStickers()
    }
    @objc func growSticker() { changeSticker(factor:1.15) }
    @objc func shrinkSticker() { changeSticker(factor:1/1.15) }
    @objc func leftSticker() { changeSticker(angle: -Double.pi/12) }
    @objc func rightSticker() { changeSticker(angle:Double.pi/12) }
    @objc func deleteSticker() { stickerStore.delete();refreshStickers() }
    override func menu(for event:NSEvent) -> NSMenu? {
        guard stickerMode else { return nil }
        let p=surface.canonical(convert(event.locationInWindow,from:nil))
        stickerStore.selected=stickerStore.hit(p)
        guard stickerStore.selected != nil else { return nil }
        let menu=NSMenu();menu.delegate=self
        for (title,action) in [("放大",#selector(growSticker)),("缩小",#selector(shrinkSticker)),("向左旋转 15°",#selector(leftSticker)),("向右旋转 15°",#selector(rightSticker)),("删除图案",#selector(deleteSticker))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        return menu
    }
    func menuWillOpen(_ menu:NSMenu) { stickerMenuOpen=true }
    func menuDidClose(_ menu:NSMenu) { stickerMenuOpen=false }
    override func magnify(with event:NSEvent) { if stickerMode { changeSticker(factor:max(0.1,1+Double(event.magnification))) } else { super.magnify(with:event) } }
    override func rotate(with event:NSEvent) { if stickerMode { changeSticker(angle: -Double(event.rotation) * .pi/180) } else { super.rotate(with:event) } }
    func refreshDrawing() { displayedDrawing = surface.warpDetailed(drawingStore.bitmap()); needsDisplay = true }
    func setPen(_ color:PenColor?, erasing: Bool = false) {
        if editor != nil { commit() }
        drawingStore.finish(); pointerHeld=false; pendingClick=nil; last=nil; active=nil; moving=false;eraserPoint=nil
        toolButton.isEnabled=true
        toolButton.inkColor = erasing ? NSColor.darkGray : color?.ink ?? NSColor(calibratedRed:0.31,green:0.20,blue:0.19,alpha:1)
        stickerMode=false;stickerDragPoint=nil
        penMode = color != nil || erasing
        drawingEraserMode = erasing
        if let color { penColor=color }
    }
    var hasHandContent:Bool {
        !notes.isEmpty || !drawingStore.strokes.isEmpty || !stickerStore.items.isEmpty || !(editor?.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)
    }
    var canUndoWash:Bool { washBackup != nil && !hasHandContent && !pointerHeld }
    @discardableResult func washHand() -> Bool {
        guard !pointerHeld else { return false }
        commit()
        guard hasHandContent else { return false }
        save()
        let backup=HandWashBackup(notes:notes,strokes:drawingStore.strokes,stickers:stickerStore.items)
        do {
            let data=try JSONEncoder().encode(backup)
            try data.write(to:folder.appendingPathComponent("wash-backup.json"),options:.atomic)
        } catch { NSSound.beep();return false }
        washBackup=backup
        notes=[];layers=[];detailedLayers=[];sourceLayers=[];sourceDetailedLayers=[];smudgeHistory=[];pendingSmudge=nil
        selected=nil;active=nil;last=nil;pendingClick=nil;stickerDragPoint=nil;stickerDragRecorded=false
        drawingStore.replaceAll([]);stickerStore.replaceAll([])
        rebuildInk();refreshDrawing();refreshStickers();save()
        return true
    }
    @objc func undoWash() {
        guard canUndoWash,let backup=washBackup else { return }
        notes=backup.notes;restoreLayers()
        drawingStore.replaceAll(backup.strokes);stickerStore.replaceAll(backup.stickers)
        refreshDrawing();refreshStickers();save()
        // Content is restored before retiring the persistent recovery copy.
        washBackup=nil
        try? FileManager.default.removeItem(at:folder.appendingPathComponent("wash-backup.json"))
    }
    @objc func undoCurrent() {
        guard editor == nil,!pointerHeld else { return }
        if canUndoWash { undoWash();return }
        if stickerMode { stickerStore.undo();refreshStickers() }
        else if penMode { drawingStore.undo(); refreshDrawing() } else { undoSmudge() }
    }
    func startEditor(at displayPoint:NSPoint) {
        guard onSkin(displayPoint), let rect = writingRect(at:surface.canonical(displayPoint)) else { return }
        let field = makeEditor(frame:rect)
        editor = field; addSubview(field); window?.makeKey(); window?.makeFirstResponder(field); needsDisplay = true
    }
    func writingRect(at p: NSPoint) -> NSRect? {
        let angle = surface.writingAngle(at: p)
        let axis = NSPoint(x: cos(angle), y: sin(angle)), normal = NSPoint(x: -sin(angle), y: cos(angle))
        var fallback: NSRect?
        for back in stride(from: 0.0, through: 104, by: 8) {
            for sideways in [0.0,-8,8,-16,16] {
                let anchor = NSPoint(x: p.x-normal.x*(10+sideways)-axis.x*back, y: p.y-normal.y*(10+sideways)-axis.y*back)
                guard anchor.x >= 2, anchor.y >= 2, anchor.x < 610, anchor.y < 400,
                      abs(surface.writingAngle(at: anchor)-angle) < 0.1 else { continue }
                var width = min(190.0, bounds.width-anchor.x-2)
                for offset in stride(from: 2.0, through: width, by: 2) {
                    let top = surface.display(surface.orient(NSPoint(x:anchor.x+offset,y:anchor.y+3),anchor:anchor,angle:angle))
                    let bottom = surface.display(surface.orient(NSPoint(x:anchor.x+offset,y:anchor.y+20),anchor:anchor,angle:angle))
                    if !onSkin(top) || !onSkin(bottom) { width = offset-2; break }
                }
                let rect = NSRect(origin:anchor,size:NSSize(width:width,height:32))
                if width >= 60 { return rect }
                if width >= 26 && width > (fallback?.width ?? 0) { fallback = rect }
            }
        }
        return fallback
    }
    func handwriting(_ size: CGFloat) -> NSFont {
        NSFont(name: "HannotateSC-W5", size: size) ?? NSFont(name: "STKaiti", size: size) ?? NSFont.systemFont(ofSize: size)
    }
    func makeEditor(frame: NSRect) -> NSTextView {
        let field = SurfaceTextView(frame: frame.offsetBy(dx: 0, dy: -22))
        field.surface = surface
        field.setFrameSize(NSSize(width: frame.width, height: frame.height+44))
        field.allowsUndo = true
        field.isRichText = false; field.importsGraphics = false
        field.drawsBackground = false; field.focusRingType = .none
        field.textContainerInset = NSSize(width: 0, height: 22); field.textContainer?.lineFragmentPadding = 0
        field.isHorizontallyResizable = false; field.isVerticallyResizable = false
        field.textContainer?.widthTracksTextView = true; field.textContainer?.heightTracksTextView = false
        field.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 2
        field.typingAttributes = [.font: handwriting(Self.defaultFontSize), .foregroundColor: NSColor(calibratedRed: 0.24, green: 0.19, blue: 0.40, alpha: 0.92), .paragraphStyle: paragraph]
        field.font = handwriting(Self.defaultFontSize); field.textColor = NSColor(calibratedRed: 0.24, green: 0.19, blue: 0.40, alpha: 0.92)
        field.defaultParagraphStyle = paragraph
        field.insertionPointColor = field.textColor!
        field.delegate = self
        return field
    }
    func textDidChange(_ notification: Notification) {
        guard let field = editor, let manager = field.layoutManager, let container = field.textContainer else { return }
        manager.ensureLayout(for: container)
        let height = max(32, ceil(manager.usedRect(for: container).maxY)+46)
        field.setFrameSize(NSSize(width: field.frame.width, height: height))
        needsDisplay = true
    }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else { commit() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { editor?.removeFromSuperview(); editor = nil; needsDisplay = true; return true }
        return false
    }
    func commit() {
        guard let field = editor else { return }
        let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let manager = field.layoutManager, let container = field.textContainer {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let width = min(field.frame.width, ceil(used.maxX)+2)
            let rect = NSRect(x: field.frame.minX+field.textContainerOrigin.x, y: field.frame.minY+field.textContainerOrigin.y, width: width, height: ceil(used.maxY)+2)
            let surfaceField = field as! SurfaceTextView
            let source = surfaceField.contentBitmap(scale: 1), detail = surfaceField.contentBitmap(scale: 2)
            sourceLayers.append(source); sourceDetailedLayers.append(detail)
            let note = Note(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, sourceOffsetX: surfaceField.contentOrigin.x-rect.minX, sourceOffsetY: surfaceField.contentOrigin.y-rect.minY, writingAngle: surfaceField.angle, inkCoverage: Self.coverage(source))
            notes.append(note)
            layers.append(projectSource(source,note:note,scale:1))
            detailedLayers.append(projectSource(detail,note:note,scale:2))
            rebuildInk()
        }
        field.removeFromSuperview(); editor = nil; window?.makeFirstResponder(self); needsDisplay = true; save()
    }
    func beginSmudge(_ i: Int) {
        guard pendingSmudge == nil else { return }
        if notes[i].inkCoverage == nil { notes[i].inkCoverage = Self.coverage(layers[i]) }
        let detail = detailedLayers[i].map { Data(bytes:$0.bitmapData!,count:$0.bytesPerRow*$0.pixelsHigh) }
        let source = sourceLayers[i].map { Data(bytes:$0.bitmapData!,count:$0.bytesPerRow*$0.pixelsHigh) }
        let sourceDetail = sourceDetailedLayers[i].map { Data(bytes:$0.bitmapData!,count:$0.bytesPerRow*$0.pixelsHigh) }
        pendingSmudge = SmudgeSnapshot(index:i,note:notes[i],pixels:Data(bytes:layers[i].bitmapData!,count:layers[i].bytesPerRow*427),detailedPixels:detail,sourcePixels:source,sourceDetailedPixels:sourceDetail)
    }
    func finishSmudge() {
        if let snapshot = pendingSmudge {
            let current = Data(bytes: layers[snapshot.index].bitmapData!, count: layers[snapshot.index].bytesPerRow*427)
            if snapshot.changed || current != snapshot.pixels || notes[snapshot.index].done != snapshot.note.done || notes[snapshot.index].distance != snapshot.note.distance || notes[snapshot.index].reversals != snapshot.note.reversals {
                smudgeHistory.append(snapshot)
                if smudgeHistory.count > 30 { smudgeHistory.removeFirst() }
            }
        }
        pendingSmudge = nil
    }
    @objc func undoSmudge() {
        guard editor == nil, !pointerHeld, let snapshot = smudgeHistory.popLast() else { return }
        let restored = Self.blank()
        snapshot.pixels.withUnsafeBytes { bytes in
            restored.bitmapData!.update(from: bytes.bindMemory(to: UInt8.self).baseAddress!, count: snapshot.pixels.count)
        }
        notes[snapshot.index] = snapshot.note
        layers[snapshot.index] = restored
        if let pixels = snapshot.detailedPixels {
            let detail = Self.blank(scale:2)
            pixels.withUnsafeBytes { detail.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:pixels.count) }
            detailedLayers[snapshot.index] = detail
        } else { detailedLayers[snapshot.index] = nil }
        if let pixels = snapshot.sourcePixels, let source = sourceLayers[snapshot.index] {
            pixels.withUnsafeBytes { source.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:pixels.count) }
        }
        if let pixels = snapshot.sourceDetailedPixels, let source = sourceDetailedLayers[snapshot.index] {
            pixels.withUnsafeBytes { source.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:pixels.count) }
        }
        selected = snapshot.note.done ? nil : snapshot.index
        rebuildInk(); needsDisplay = true; save()
    }
    override func mouseDragged(with event: NSEvent) {
        let displayPoint = convert(event.locationInWindow,from:nil)
        if stickerMode {
            let p=surface.canonical(displayPoint)
            if let before=stickerDragPoint {
                let changed=stickerStore.transform(dx:p.x-before.x,dy:p.y-before.y,record:!stickerDragRecorded,valid:{self.onSkin(self.surface.display($0))})
                if changed { stickerDragRecorded=true;stickerDragPoint=p;refreshStickers() }
            }
            return
        }
        if penMode {
            let point=surface.canonical(displayPoint)
            if drawingEraserMode { eraserPoint=point }
            drawingStore.append(point,inside:drawingEraserMode || onSkin(displayPoint)); refreshDrawing(); return
        }
        if let click = pendingClick, hypot(displayPoint.x-click.point.x,displayPoint.y-click.point.y) > 4 { pendingClick?.moved = true }
        let handPoint = surface.canonical(displayPoint)
        if active == nil, pendingClick?.moved == true {
            if let click = pendingClick {
                let start = surface.canonical(click.point)
                if let i = notes.indices.reversed().first(where:{ !notes[$0].done && eraserTouches(from:start,to:handPoint,index:$0) }) {
                    active = i; moving = false; last = pointInNote(start,note:notes[i]); direction = 0
                    pendingClick = nil
                }
            }
        }
        guard let before = last, let i = active else { return }
        let p = moving ? handPoint : pointInNote(handPoint, note: notes[i])
        let dx = p.x-before.x, dy = p.y-before.y, length = hypot(dx, dy)
        guard length > 0.5 else { return }
        if moving {
            if moveNote(i, dx: Int(dx.rounded()), dy: Int(dy.rounded())) { last = p }
            return
        }
        eraserPoint = p
        if !notes[i].done {
            beginSmudge(i)
            ink = layers[i]
            let changed = smudge(p,dx:dx,dy:dy)
            layers[i] = ink
            if changed {
                let remaining = Self.coverage(sourceLayers[i] ?? layers[i]), original = notes[i].inkCoverage ?? remaining
                if original > 0 && remaining <= original*0.01 {
                    layers[i] = Self.blank()
                    if detailedLayers[i] != nil { detailedLayers[i] = Self.blank(scale:2) }
                    for source in [sourceLayers[i],sourceDetailedLayers[i]].compactMap({$0}) {
                        source.bitmapData!.initialize(repeating:0,count:source.bytesPerRow*source.pixelsHigh)
                    }
                    notes[i].done = true
                }
                rebuildInk(changedIndex:i)
            }
        }
        needsDisplay = true
        last = p
    }
    // Keep the existing undo entry points; erasing now only removes pigment in place.
    @discardableResult func smudge(_ p: NSPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        let start = NSPoint(x:p.x-dx,y:p.y-dy)
        var changed = eraseBitmap(ink,from:start,to:p)
        if let i = active ?? pendingSmudge?.index, let detail = detailedLayers[i] {
            changed = eraseBitmap(detail,from:start,to:p) || changed
        }
        if let i = active ?? pendingSmudge?.index {
            let origin = sourceOrigin(notes[i])
            if let source = sourceLayers[i] { changed = eraseBitmap(source,from:start,to:p,scale:1,origin:origin) || changed }
            if let source = sourceDetailedLayers[i] { changed = eraseBitmap(source,from:start,to:p,scale:2,origin:origin) || changed }
        }
        if changed { pendingSmudge?.changed = true }
        return changed
    }
    @discardableResult func eraseBitmap(_ bitmap: NSBitmapImageRep, from start: NSPoint, to end: NSPoint, scale explicitScale: Double? = nil, origin: NSPoint = .zero) -> Bool {
        let scale = explicitScale ?? Double(bitmap.pixelsWide)/640
        let region = eraserBounds(from:start,to:end).intersection(NSRect(origin:origin,size:NSSize(width:Double(bitmap.pixelsWide)/scale,height:Double(bitmap.pixelsHigh)/scale)))
        guard !region.isEmpty else { return false }
        let radius = Self.eraserRadius, edge: CGFloat = 0.75
        let coreSquared = (radius-edge)*(radius-edge), radiusSquared = radius*radius
        let pixels = bitmap.bitmapData!
        var changed = false
        for y in max(0,Int(floor((region.minY-origin.y)*scale)))..<min(bitmap.pixelsHigh,Int(ceil((region.maxY-origin.y)*scale))) {
            for x in max(0,Int(floor((region.minX-origin.x)*scale)))..<min(bitmap.pixelsWide,Int(ceil((region.maxX-origin.x)*scale))) {
                let offset = y*bitmap.bytesPerRow+x*4
                guard pixels[offset+3] > 0 else { continue }
                let d = Self.segmentDistanceSquared(NSPoint(x:origin.x+Double(x)/scale,y:origin.y+Double(y)/scale),from:start,to:end)
                guard d < radiusSquared else { continue }
                let keep = d <= coreSquared ? 0 : (sqrt(d)-(radius-edge))/edge
                let alpha = UInt8((Double(pixels[offset+3])*keep).rounded())
                if alpha >= pixels[offset+3] { continue }
                if alpha <= 3 {
                    for c in 0..<4 { pixels[offset+c] = 0 }
                } else {
                    for c in 0..<4 { pixels[offset+c] = UInt8((Double(pixels[offset+c])*keep).rounded()) }
                }
                changed = true
            }
        }
        return changed
    }
    override func mouseUp(with event: NSEvent) {
        if stickerMode { pointerHeld=false;stickerDragPoint=nil;stickerDragRecorded=false;stickerStore.save();return }
        if penMode {
            let p=convert(event.locationInWindow,from:nil)
            drawingStore.append(surface.canonical(p),inside:drawingEraserMode || onSkin(p)); drawingStore.finish()
            pointerHeld=false;eraserPoint=nil;refreshDrawing();return
        }
        // Include the release position when event coalescing skipped the final drag sample.
        if !moving && (pendingSmudge != nil || pendingClick?.moved == true) { mouseDragged(with:event) }
        let released = convert(event.locationInWindow,from:nil)
        let click = pendingClick
        let shouldCreate = active == nil && click.map {
            !$0.moved && event.timestamp-$0.timestamp <= 0.35 && hypot(released.x-$0.point.x,released.y-$0.point.y) <= 4
        } == true
        finishSmudge(); last = nil; active = nil; moving = false; pointerHeld = false; pendingClick = nil; eraserPoint = nil
        needsDisplay = true
        save()
        if shouldCreate, let click, onSkin(released) { startEditor(at:click.point) }
    }
}
enum SelfPreview {
    static func make(_ view: HandView, scale: Int = 1) -> Data {
        let bitmap = HandView.blank(scale: scale)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])!
    }
}
struct EdgeTrigger {
    private var wasAtEdge = false
    mutating func entered(_ atEdge: Bool) -> Bool {
        let entered = atEdge && !wasAtEdge
        wasAtEdge = atEdge
        return entered
    }
    static func atEdge(_ p: NSPoint, frame: NSRect, visible: NSRect) -> Bool {
        p.x >= frame.minX && p.x <= frame.minX+3 && p.y > visible.minY+30 && p.y < visible.maxY-30
    }
    static func staysOpen(atEdge: Bool, inPanel: Bool, dragging: Bool) -> Bool {
        atEdge || inPanel || dragging
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var panel: HandPanel!; var canvas: HandView!; var status: NSStatusItem!; var timer: Timer?
    var toolMenuOpen = false
    var edgeTrigger = EdgeTrigger()
    var shown = false; var opening = false; var screen: NSScreen?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        canvas = HandView()
        panel = HandPanel(contentRect: canvas.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.contentView = canvas; panel.isReleasedWhenClosed = false
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "掌上待办")
        let menu = NSMenu()
        menu.addItem(withTitle: "伸出手", action: #selector(reveal), keyEquivalent: "")
        menu.addItem(withTitle: "撤销上次擦除", action: #selector(undoRub), keyEquivalent: "z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle:"待办模式",action:#selector(chooseTodo),keyEquivalent:"")
        for (title,tag) in [("画笔 · 黑色",1),("画笔 · 红色",2),("画笔 · 蓝色",3)] {
            let item=NSMenuItem(title:title,action:#selector(choosePen(_:)),keyEquivalent:""); item.tag=tag; menu.addItem(item)
        }
        menu.addItem(withTitle:"涂鸦橡皮擦",action:#selector(chooseDrawingEraser),keyEquivalent:"")
        menu.addItem(withTitle:"撤销涂画",action:#selector(undoDrawing),keyEquivalent:"")
        menu.addItem(withTitle:"清空涂画",action:#selector(clearDrawing),keyEquivalent:"")
        appendStickerItems(to:menu)
        menu.addItem(NSMenuItem.separator())
        let help = NSMenuItem(title: "直接拖动擦除 · ⌥拖动移动文字", action: nil, keyEquivalent: ""); help.isEnabled = false; menu.addItem(help)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出掌上待办", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }; status.menu = menu
        canvas.toolButton.target=self; canvas.toolButton.action = #selector(openWristTools)
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        reveal()
    }
    @objc func reveal() {
        guard !shown else { return }
        let point = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        screen = s; shown = true
        let height = min(427.0, s.visibleFrame.height*0.65), width = height*640/427
        panel.ignoresMouseEvents = false
        panel.setContentSize(NSSize(width: width, height: height)); canvas.setFrameSize(NSSize(width: width, height: height)); canvas.setBoundsSize(NSSize(width: 640, height: 427))
        let target = NSRect(x: s.frame.minX, y: s.visibleFrame.midY-height/2, width: width, height: height)
        panel.setFrame(target.offsetBy(dx: -width, dy: 0), display: true); panel.orderFrontRegardless()
        opening = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24; panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in self?.opening = false })
    }
    func tick() {
        let p = NSEvent.mouseLocation
        let edgeScreen = NSScreen.screens.first { EdgeTrigger.atEdge(p, frame: $0.frame, visible: $0.visibleFrame) }
        let enteredEdge = edgeTrigger.entered(edgeScreen != nil)
        if !shown {
            if enteredEdge { reveal() }
            return
        }
        if opening || toolMenuOpen || canvas.stickerMenuOpen { return }
        let local = canvas.convert(panel.convertPoint(fromScreen: p), from: nil)
        panel.ignoresMouseEvents = !canvas.interacting && !canvas.toolButton.frame.contains(local) && !canvas.onSkin(local)
        let atOwnEdge = screen.map { EdgeTrigger.atEdge(p, frame: $0.frame, visible: $0.visibleFrame) } ?? false
        // Use the panel's stable interaction area, not individual transparent image pixels.
        if EdgeTrigger.staysOpen(atEdge: atOwnEdge, inPanel: panel.frame.contains(p), dragging: canvas.pointerHeld) { return }
        canvas.commit()
        canvas.selected = nil
        shown = false
        canvas.save()
        panel.orderOut(nil)
    }
    @objc func openWristTools() {
        panel.ignoresMouseEvents=false
        canvas.commit()
        let menu=NSMenu()
        menu.addItem(withTitle:"待办模式",action:#selector(chooseTodo),keyEquivalent:"")
        menu.addItem(NSMenuItem.separator())
        for (title,tag) in [("黑色画笔",1),("红色画笔",2),("蓝色画笔",3)] {
            let item=NSMenuItem(title:title,action:#selector(choosePen(_:)),keyEquivalent:""); item.tag=tag; menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle:"涂鸦橡皮擦",action:#selector(chooseDrawingEraser),keyEquivalent:"")
        menu.addItem(withTitle:"撤销涂画",action:#selector(undoDrawing),keyEquivalent:"")
        menu.addItem(withTitle:"清空涂画",action:#selector(clearDrawing),keyEquivalent:"")
        appendStickerItems(to:menu)
        for item in menu.items where item.action != nil { item.target=self }
        toolMenuOpen=true
        defer { toolMenuOpen=false; canvas.toolButton.isEnabled=true; canvas.toolButton.needsDisplay=true; panel.ignoresMouseEvents=false }
        menu.popUp(positioning:nil,at:NSPoint(x:canvas.toolButton.frame.minX,y:canvas.toolButton.frame.minY),in:canvas)
    }
    func appendStickerItems(to menu:NSMenu) {
        menu.addItem(NSMenuItem.separator())
        let mode=NSMenuItem(title:"图案模式",action:#selector(chooseStickers),keyEquivalent:"");mode.target=self;menu.addItem(mode)
        let entry=NSMenuItem(title:"添加图案",action:nil,keyEquivalent:"")
        let catalog=NSMenu()
        for (i,item) in StickerStore.catalog.enumerated() {
            let option=NSMenuItem(title:item.1,action:#selector(insertSticker(_:)),keyEquivalent:"");option.tag=i;option.target=self;catalog.addItem(option)
        }
        entry.submenu=catalog;menu.addItem(entry)
        let hint=NSMenuItem(title:"拖动移动 · 滚动缩放 · ⌥滚动旋转",action:nil,keyEquivalent:"");hint.isEnabled=false;menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())
        let wash=NSMenuItem(title:"洗手 · 清除所有内容",action:#selector(washHand),keyEquivalent:"");wash.target=self;menu.addItem(wash)
        let recover=NSMenuItem(title:"撤销洗手",action:#selector(undoHandWash),keyEquivalent:"");recover.target=self;menu.addItem(recover)
    }
    @objc func chooseStickers() { canvas.enableStickers(); status.button?.image=NSImage(systemSymbolName:"sparkles",accessibilityDescription:"图案模式");status.button?.contentTintColor=nil }
    @objc func insertSticker(_ sender:NSMenuItem) { canvas.addSticker(StickerStore.catalog[sender.tag].0); status.button?.image=NSImage(systemSymbolName:"sparkles",accessibilityDescription:"图案模式");status.button?.contentTintColor=nil; if !shown { reveal() } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoRub) {
            if canvas.canUndoWash { menuItem.title="撤销洗手";return true }
            menuItem.title = canvas.stickerMode ? "撤销图案操作" : canvas.penMode ? "撤销涂画操作" : "撤销上次擦除"
            return (canvas.stickerMode ? canvas.stickerStore.canUndo : canvas.penMode ? canvas.drawingStore.canUndo : !canvas.smudgeHistory.isEmpty) && canvas.editor == nil && !canvas.pointerHeld
        }
        if menuItem.action == #selector(washHand) { return canvas.hasHandContent && !canvas.pointerHeld }
        if menuItem.action == #selector(undoHandWash) { return canvas.canUndoWash }
        if menuItem.action == #selector(chooseTodo) { menuItem.state = canvas.penMode || canvas.stickerMode ? .off:.on }
        if menuItem.action == #selector(chooseDrawingEraser) { menuItem.state=canvas.drawingEraserMode ? .on:.off }
        if menuItem.action == #selector(chooseStickers) { menuItem.state=canvas.stickerMode ? .on:.off }
        if menuItem.action == #selector(choosePen(_:)) {
            let color:PenColor = menuItem.tag == 1 ? .black : menuItem.tag == 2 ? .red:.blue
            menuItem.state = canvas.penMode && !canvas.drawingEraserMode && canvas.penColor == color ? .on:.off
        }
        if menuItem.action == #selector(undoDrawing) { return canvas.drawingStore.canUndo && !canvas.pointerHeld }
        if menuItem.action == #selector(clearDrawing) { return !canvas.drawingStore.strokes.isEmpty && !canvas.pointerHeld }
        return true
    }
    @objc func washHand() { _=canvas.washHand() }
    @objc func undoHandWash() { canvas.undoWash() }
    @objc func chooseTodo() {
        canvas.setPen(nil)
        status.button?.image=NSImage(systemSymbolName:"hand.raised.fill",accessibilityDescription:"掌上待办")
        status.button?.contentTintColor=nil
    }
    @objc func choosePen(_ sender:NSMenuItem) {
        canvas.setPen(sender.tag == 1 ? .black : sender.tag == 2 ? .red:.blue)
        status.button?.image=NSImage(systemSymbolName:"pencil.tip",accessibilityDescription:"手掌画笔")
        status.button?.contentTintColor=canvas.penColor.ink
        if !shown { reveal() }
    }
    @objc func chooseDrawingEraser() {
        canvas.setPen(nil,erasing:true)
        status.button?.image=NSImage(systemSymbolName:"eraser",accessibilityDescription:"涂鸦橡皮擦")
        status.button?.contentTintColor=nil
        if !shown { reveal() }
    }
    @objc func undoDrawing() { canvas.drawingStore.undo(); canvas.refreshDrawing() }
    @objc func clearDrawing() { canvas.drawingStore.clear(); canvas.refreshDrawing() }
    @objc func undoRub() { canvas.undoCurrent(); if !shown { reveal() } }
    @objc func quit() { canvas.commit(); canvas.save(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { canvas.save() }
}
final class ToolActionProbe: NSObject {
    var count=0
    @objc func openTools(_ sender:Any?) { count += 1 }
}
let app = NSApplication.shared
if CommandLine.arguments.contains("--drag-benchmark") || CommandLine.arguments.contains("--erase-benchmark") {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HandTodo-Drag-"+UUID().uuidString)
    let view = HandView(storage:folder)
    for _ in 0..<8 {
        let input = view.makeEditor(frame:NSRect(x:190,y:200,width:190,height:32))
        input.string = "下午交稿拿快递";view.editor=input;view.commit()
    }
    if CommandLine.arguments.contains("--erase-benchmark") {
        let window = HandPanel(contentRect:view.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.contentView=view
        let low = Data(bytes:view.layers[0].bitmapData!,count:view.layers[0].bytesPerRow*427)
        let high = Data(bytes:view.detailedLayers[0]!.bitmapData!,count:view.detailedLayers[0]!.bytesPerRow*854)
        var timings:[Double]=[]
        for _ in 0..<12 {
            low.withUnsafeBytes { view.layers[0].bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:low.count) }
            high.withUnsafeBytes { view.detailedLayers[0]!.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:high.count) }
            view.notes[0].done=false;view.notes[0].distance=0;view.notes[0].reversals=0
            view.pendingSmudge=nil;view.rebuildInk(changedIndex:0)
            view.active=0;view.moving=false;view.pointerHeld=true;view.last=NSPoint(x:195,y:208)
            let target=view.surface.display(view.notePoint(NSPoint(x:270,y:208),note:view.notes[0]))
            let event=NSEvent.mouseEvent(with:.leftMouseDragged,location:view.convert(target,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            let start=ProcessInfo.processInfo.systemUptime
            view.mouseDragged(with:event)
            timings.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        print("ERASE: 8 notes, 75 point pointer segment including undo snapshot, mean \(timings.reduce(0,+)/Double(timings.count)) ms, max \(timings.max()!) ms")
        try? FileManager.default.removeItem(at:folder)
        exit(0)
    }
    var times:[Double]=[]
    for _ in 0..<12 {
        let start = ProcessInfo.processInfo.systemUptime
        precondition(view.moveNote(0,dx:1,dy:0))
        times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        precondition(view.moveNote(0,dx:-1,dy:0))
    }
    print("DRAG: 8 notes, mean \(times.reduce(0,+)/Double(times.count)) ms, max \(times.max()!) ms")
    try? FileManager.default.removeItem(at:folder)
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    let testOutput=Bundle.main.bundleURL.deletingLastPathComponent()
    var trigger = EdgeTrigger()
    precondition(trigger.entered(true), "Entering the edge must reveal")
    for _ in 0..<120 { precondition(!trigger.entered(true), "Stationary edge cannot retrigger") }
    precondition(!trigger.entered(false) && trigger.entered(true), "Leaving and reentering must reveal again")
    precondition(EdgeTrigger.staysOpen(atEdge: true, inPanel: false, dragging: false), "Edge outside silhouette must stay open")
    precondition(EdgeTrigger.staysOpen(atEdge: false, inPanel: true, dragging: false), "Finger gaps must stay open")
    precondition(!EdgeTrigger.staysOpen(atEdge: false, inPanel: false, dragging: false), "Leaving must hide immediately")
    precondition(EdgeTrigger.staysOpen(atEdge: false, inPanel: false, dragging: true), "Dragging must remain uninterrupted")
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("HandTodo-"+UUID().uuidString)
    func eraserPixels(_ bitmap: NSBitmapImageRep) -> Data {
        Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    let eraseView = HandView(storage:temp.appendingPathComponent("precise-erasing"))
    for scale in [1,2] {
        let solid = HandView.blank(scale:scale)
        for y in 195*scale..<225*scale { for x in 180*scale..<290*scale {
            let o=y*solid.bytesPerRow+x*4
            for (c,value) in [UInt8(100),60,150,255].enumerated() { solid.bitmapData![o+c]=value }
        } }
        let original = eraserPixels(solid)
        precondition(eraseView.eraseBitmap(solid,from:NSPoint(x:190,y:208),to:NSPoint(x:280,y:208)), "A fast pointer segment must erase continuously")
        for x in 190*scale..<280*scale {
            let o=208*scale*solid.bytesPerRow+x*4
            precondition((0..<4).allSatisfy { solid.bitmapData![o+$0] == 0 }, "The eraser core must be completely clean without gaps")
        }
        let outside=218*scale*solid.bytesPerRow+220*scale*4
        precondition(solid.bitmapData![outside+3] == 255, "Pigment outside the small eraser radius must remain untouched")
        let result = eraserPixels(solid)
        precondition(zip(original,result).allSatisfy { $1 <= $0 }, "Erasing must never move pigment, spread color or darken any pixel")
    }
    for (y,text) in [(200.0,"擦除精度测试"),(230.0,"旁边文字保留")] {
        let input=eraseView.makeEditor(frame:NSRect(x:190,y:y,width:190,height:32))
        input.string=text;eraseView.editor=input;eraseView.commit()
    }
    eraseView.drawingStore.begin(NSPoint(x:220,y:300),color:.blue)
    eraseView.drawingStore.append(NSPoint(x:260,y:305),inside:true);eraseView.drawingStore.finish();eraseView.refreshDrawing()
    eraseView.addSticker("02-rocket");eraseView.setPen(nil)
    let originalLow=eraserPixels(eraseView.layers[0]), originalHigh=eraserPixels(eraseView.detailedLayers[0]!)
    let neighbor=eraserPixels(eraseView.detailedLayers[1]!), artwork=eraserPixels(eraseView.displayedStickers), pen=eraserPixels(eraseView.displayedDrawing)
    let eraseWindow=HandPanel(contentRect:eraseView.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    eraseWindow.contentView=eraseView
    let eraseBounds=HandSurface.inkBounds(eraseView.layers[0])
    let eraseStart=NSPoint(x:eraseBounds.minX-12,y:eraseBounds.midY), eraseEnd=NSPoint(x:eraseBounds.maxX+12,y:eraseBounds.midY)
    func eraseGesture(_ type:NSEvent.EventType,_ point:NSPoint) {
        let screen=eraseView.surface.display(eraseView.notePoint(point,note:eraseView.notes[0]))
        let event=NSEvent.mouseEvent(with:type,location:eraseView.convert(screen,to:nil),modifierFlags:[],timestamp:0,windowNumber:eraseWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
        switch type {
        case .leftMouseDown:eraseView.mouseDown(with:event)
        case .leftMouseDragged:eraseView.mouseDragged(with:event)
        default:eraseView.mouseUp(with:event)
        }
    }
    eraseGesture(.leftMouseDown,eraseStart)
    eraseGesture(.leftMouseDragged,NSPoint(x:eraseBounds.midX,y:eraseBounds.midY))
    eraseGesture(.leftMouseUp,eraseEnd)
    precondition(eraseView.notes[0].done && eraserPixels(eraseView.layers[0]).allSatisfy { $0 == 0 } && eraserPixels(eraseView.detailedLayers[0]!).allSatisfy { $0 == 0 }, "Sweeping across the full word must complete it with zero residue, even when the pointer ends outside the word")
    precondition(eraseView.smudgeHistory.count == 1 && eraseView.eraserPoint == nil, "One pointer gesture must create exactly one undo step and remove its cursor ring")
    precondition(eraserPixels(eraseView.detailedLayers[1]!) == neighbor && eraserPixels(eraseView.displayedStickers) == artwork && eraserPixels(eraseView.displayedDrawing) == pen, "Precise erasing must preserve nearby text, stickers and freehand strokes")
    let erasedReload=HandView(storage:eraseView.folder)
    precondition(erasedReload.notes[0].done && eraserPixels(erasedReload.detailedLayers[0]!).allSatisfy { $0 == 0 }, "A fully erased word must remain clean and completed after restart")
    eraseView.undoSmudge()
    precondition(!eraseView.notes[0].done && eraserPixels(eraseView.layers[0]) == originalLow && eraserPixels(eraseView.detailedLayers[0]!) == originalHigh, "Undo must restore exact high resolution pigment and completion state")
    try! SelfPreview.make(eraseView,scale:2).write(to:testOutput.appendingPathComponent("eraser-before-preview.png"))
    let partialEnd=NSPoint(x:eraseBounds.midX,y:eraseBounds.midY)
    eraseGesture(.leftMouseDown,eraseStart);eraseGesture(.leftMouseDragged,partialEnd);eraseGesture(.leftMouseUp,partialEnd)
    precondition(!eraseView.notes[0].done && eraserPixels(eraseView.detailedLayers[0]!) != originalHigh, "Partial erasing must leave the remaining letters intact without prematurely completing the task")
    try! SelfPreview.make(eraseView,scale:2).write(to:testOutput.appendingPathComponent("eraser-after-preview.png"))
    // Freehand erasing has a separate tool and undo transaction, never a global mask.
    let drawingEraseView=HandView(storage:temp.appendingPathComponent("drawing-eraser"))
    let drawingEraseInput=drawingEraseView.makeEditor(frame:NSRect(x:190,y:200,width:190,height:32))
    drawingEraseInput.string="文字保留";drawingEraseView.editor=drawingEraseInput;drawingEraseView.commit()
    drawingEraseView.addSticker("02-rocket")
    drawingEraseView.drawingStore.begin(NSPoint(x:210,y:280),color:.blue)
    drawingEraseView.drawingStore.append(NSPoint(x:290,y:280),inside:true);drawingEraseView.drawingStore.finish();drawingEraseView.refreshDrawing()
    let drawingOriginal=eraserPixels(drawingEraseView.drawingStore.bitmap())
    let drawingText=eraserPixels(drawingEraseView.displayedInk), drawingSticker=eraserPixels(drawingEraseView.displayedStickers)
    drawingEraseView.setPen(nil,erasing:true)
    precondition(drawingEraseView.penMode && drawingEraseView.drawingEraserMode && !drawingEraseView.stickerMode, "Choosing the freehand eraser must switch to an isolated drawing tool")
    let drawingEraseWindow=HandPanel(contentRect:drawingEraseView.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    drawingEraseWindow.contentView=drawingEraseView
    func drawingEraseGesture(_ type:NSEvent.EventType,_ point:NSPoint) {
        let screen=drawingEraseView.surface.display(point)
        let event=NSEvent.mouseEvent(with:type,location:drawingEraseView.convert(screen,to:nil),modifierFlags:[],timestamp:0,windowNumber:drawingEraseWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
        switch type {
        case .leftMouseDown:drawingEraseView.mouseDown(with:event)
        case .leftMouseDragged:drawingEraseView.mouseDragged(with:event)
        default:drawingEraseView.mouseUp(with:event)
        }
    }
    drawingEraseGesture(.leftMouseDown,NSPoint(x:250,y:268))
    drawingEraseGesture(.leftMouseDragged,NSPoint(x:250,y:280))
    let liveDrawing=eraserPixels(drawingEraseView.drawingStore.bitmap())
    drawingEraseView.drawingStore.finish()
    precondition(eraserPixels(drawingEraseView.drawingStore.bitmap()) == liveDrawing, "Incremental eraser preview must exactly match the saved vector replay")
    // Ending the UI gesture must not add a second undo entry.
    drawingEraseGesture(.leftMouseUp,NSPoint(x:250,y:280))
    let drawingCut=drawingEraseView.drawingStore.bitmap()
    precondition(drawingCut.bitmapData![560*drawingCut.bytesPerRow+500*4+3] == 0, "The freehand eraser must remove the touched part of a stroke completely")
    precondition(drawingCut.bitmapData![560*drawingCut.bytesPerRow+440*4+3] > 0, "The rest of the same stroke must remain visible")
    precondition(eraserPixels(drawingEraseView.displayedInk) == drawingText && eraserPixels(drawingEraseView.displayedStickers) == drawingSticker, "Freehand erasing must never modify text or stickers")
    let drawingErasedReload=HandView(storage:drawingEraseView.folder)
    precondition(eraserPixels(drawingErasedReload.displayedDrawing) == eraserPixels(drawingEraseView.displayedDrawing), "Erased freehand content must survive reopening exactly")
    drawingEraseView.undoCurrent()
    precondition(eraserPixels(drawingEraseView.drawingStore.bitmap()) == drawingOriginal && drawingEraseView.drawingStore.strokes.count == 1, "One undo must restore the entire freehand eraser gesture")
    drawingEraseGesture(.leftMouseDown,NSPoint(x:250,y:268))
    drawingEraseGesture(.leftMouseDragged,NSPoint(x:250,y:292))
    drawingEraseGesture(.leftMouseUp,NSPoint(x:250,y:292))
    try! SelfPreview.make(drawingEraseView,scale:2).write(to:testOutput.appendingPathComponent("drawing-eraser-preview.png"))
    drawingEraseView.setPen(.red)
    precondition(!drawingEraseView.drawingEraserMode && drawingEraseView.penMode, "Choosing a pen must exit freehand erasing")
    drawingEraseView.drawingStore.begin(NSPoint(x:250,y:280),color:.red);drawingEraseView.drawingStore.finish();drawingEraseView.refreshDrawing()
    let repaint=drawingEraseView.drawingStore.bitmap()
    precondition(repaint.bitmapData![560*repaint.bytesPerRow+500*4+3] > 0, "New strokes must remain drawable over previously erased areas")
    let emptyDrawing=DrawingStore(folder:temp.appendingPathComponent("empty-drawing-eraser"))
    emptyDrawing.beginErasing(NSPoint(x:200,y:250));emptyDrawing.append(NSPoint(x:220,y:250),inside:true);emptyDrawing.finish()
    precondition(emptyDrawing.strokes.isEmpty && !emptyDrawing.canUndo, "Erasing empty space must not create content or an undo entry")
    let view = HandView(storage: temp)
    let field = view.makeEditor(frame: NSRect(x: 190, y: 200, width: 190, height: 32))
    field.string = "下午交稿"; view.editor = field; view.commit()
    precondition(view.notes.count == 1, "Input must create one note")
    try! view.ink.representation(using: .png, properties: [:])!.write(to: testOutput.appendingPathComponent("ink-test.png"))
    let original = Data(bytes: view.ink.bitmapData!, count: view.ink.bytesPerRow*427)
    precondition(original.contains(where: { $0 != 0 }), "Text must draw visible pixels")
    let originalDetail = Data(bytes:view.detailedLayers[0]!.bitmapData!,count:view.detailedLayers[0]!.bytesPerRow*854)
    let oldRect = view.notes[0].rect
    precondition(view.moveNote(0, dx: 12, dy: 10), "Text must move on skin")
    precondition(view.notes[0].x == oldRect.minX+12 && view.notes[0].y == oldRect.minY+10, "Hit bounds must follow text")
    precondition(!view.moveNote(0, dx: 640, dy: 0), "Cannot move off hand")
    view.save()
    let movedReload = HandView(storage: temp)
    precondition(movedReload.notes[0].rect == view.notes[0].rect, "Position must persist")
    precondition(view.moveNote(0, dx: -12, dy: -10), "Text must move back")
    precondition(Data(bytes: view.ink.bitmapData!, count: view.ink.bytesPerRow*427) == original, "Moving must preserve ink exactly")
    precondition(Data(bytes:view.detailedLayers[0]!.bitmapData!,count:view.detailedLayers[0]!.bytesPerRow*854) == originalDetail, "Moving must preserve high resolution glyphs exactly")
    for _ in 0..<4 {
        for x in stride(from: 190.0, to: 290.0, by: 3) { view.smudge(NSPoint(x: x, y: 215), dx: 3, dy: 0) }
        for x in stride(from: 290.0, to: 190.0, by: -3) { view.smudge(NSPoint(x: x, y: 215), dx: -3, dy: 0) }
    }
    let smeared = Data(bytes: view.ink.bitmapData!, count: view.ink.bytesPerRow*427)
    precondition(original != smeared, "Erasing must remove pigment")
    try! view.ink.representation(using: .png, properties: [:])!.write(to: testOutput.appendingPathComponent("smudge-test.png"))
    view.layers[0] = view.ink
    view.notes[0].done = true; view.save()
    let restored = HandView(storage: temp)
    precondition(restored.notes.count == 1 && restored.notes[0].done, "Completion must persist")
    let restoredData = Data(bytes: restored.ink.bitmapData!, count: restored.ink.bytesPerRow*427)
    precondition(restoredData.contains(where: { $0 != 0 }), "Existing partial ink must persist")
    let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 427, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2560, bitsPerPixel: 32)!
    view.cacheDisplay(in: view.bounds, to: preview)
    try! preview.representation(using: .png, properties: [:])!.write(to: testOutput.appendingPathComponent("preview.png"))
    let overlap = HandView(storage: temp.appendingPathComponent("overlap"))
    for text in ["拿快递", "回消息"] {
        let field = overlap.makeEditor(frame: NSRect(x: 190, y: 200, width: 190, height: 32))
        field.string = text; overlap.editor = field; overlap.commit()
    }
    let untouched = Data(bytes: overlap.layers[1].bitmapData!, count: overlap.layers[1].bytesPerRow*427)
    precondition(overlap.moveNote(0, dx: 10, dy: 10), "Overlapping text must move")
    precondition(Data(bytes: overlap.layers[1].bitmapData!, count: overlap.layers[1].bytesPerRow*427) == untouched, "Other text must remain unchanged")
    let legacyFolder = temp.appendingPathComponent("legacy")
    try! FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
    var legacyNote = overlap.notes[0]; legacyNote.pigment = nil; legacyNote.fontSize = nil
    try! JSONEncoder().encode([legacyNote]).write(to: legacyFolder.appendingPathComponent("notes.json"))
    try! overlap.layers[0].representation(using: .png, properties: [:])!.write(to: legacyFolder.appendingPathComponent("ink.png"))
    let legacy = HandView(storage: legacyFolder)
    precondition(abs(legacy.notes[0].width-legacyNote.width*0.8) < 0.01, "Existing notes must shrink once")
    legacy.save()
    let legacyReload = HandView(storage:legacyFolder)
    precondition(legacyReload.notes[0].width == legacy.notes[0].width, "Restart must not shrink notes again")
    precondition(legacy.layers.count == 1 && legacy.moveNote(0, dx: 5, dy: 0), "Older saved notes must remain movable")
    // Exercise the actual NSTextInputClient marked-text path at the palm and finger edges.
    for (name,frame) in [("palm-edge",NSRect(x:190,y:360,width:60,height:32)),("thumb-edge",NSRect(x:250,y:110,width:65,height:32))] {
        let overflow = HandView(storage:temp.appendingPathComponent(name))
        let input = overflow.makeEditor(frame:frame) as! SurfaceTextView
        overflow.editor=input
        let sentence=String(repeating:"边界中文输入自动换行",count:18)
        input.insertText(sentence,replacementRange:NSRange(location:0,length:0))
        let end=(input.string as NSString).length
        input.setSelectedRange(NSRange(location:end,length:0))
        input.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        precondition(input.hasMarkedText(),"Composition must remain active beyond the palm boundary")
        precondition(!overflow.textView(input,doCommandBy:#selector(NSResponder.insertNewline(_:))),"Return during composition must remain available to the input method")
        input.insertText("中文",replacementRange:input.markedRange())
        precondition(input.string == sentence+"中文" && !input.hasMarkedText(),"Committed Chinese must replace pinyin even when the note exceeds the hand")
        overflow.textDidChange(Notification(name:NSText.didChangeNotification))
        precondition(input.frame.maxY > overflow.bounds.maxY,"Long text must grow beyond the hand rather than rejecting input")
        let layout=input.layoutManager!;layout.ensureLayout(for:input.textContainer!)
        precondition(layout.usedRect(for:input.textContainer!).height > 427,"Long text must wrap into additional lines")
        overflow.commit()
        let originalSource=eraserPixels(overflow.sourceLayers[0]!), originalDetail=eraserPixels(overflow.sourceDetailedLayers[0]!)
        precondition(overflow.sourceLayers[0]!.size.height > 427,"Source must retain all off-canvas lines")
        if name == "palm-edge" {
            try! SelfPreview.make(overflow,scale:2).write(to:testOutput.appendingPathComponent("overflow-before-preview.png"))
            let original=eraserPixels(overflow.layers[0]), originalProjected=eraserPixels(overflow.detailedLayers[0]!)
            let delta=Int((300-overflow.sourceOrigin(overflow.notes[0]).y-overflow.sourceLayers[0]!.size.height).rounded())
            precondition(overflow.moveNote(0,dx:0,dy:delta),"An overflowing note must move even while many lines remain outside the hand")
            let tail=overflow.layers[0]
            precondition((260..<300).contains{y in (190..<250).contains{x in tail.bitmapData![y*tail.bytesPerRow+x*4+3]>0}},"Dragging must reveal the off-canvas final lines")
            try! SelfPreview.make(overflow,scale:2).write(to:testOutput.appendingPathComponent("overflow-after-preview.png"))
            overflow.save()
            let reload=HandView(storage:overflow.folder)
            precondition(eraserPixels(reload.sourceLayers[0]!) == originalSource && eraserPixels(reload.sourceDetailedLayers[0]!) == originalDetail,"All overflow ink must survive restart exactly")
            precondition(reload.moveNote(0,dx:0,dy:-delta),"Hidden first lines must remain recoverable after restart")
            precondition(eraserPixels(reload.layers[0]) == original && eraserPixels(reload.detailedLayers[0]!) == originalProjected,"Off-canvas round-trip must preserve every original pixel")
            reload.active=0;reload.beginSmudge(0);reload.ink=reload.layers[0]
            _=reload.smudge(NSPoint(x:205,y:370),dx:10,dy:0);reload.layers[0]=reload.ink;reload.finishSmudge();reload.active=nil
            precondition(eraserPixels(reload.sourceLayers[0]!) != originalSource,"Erasing must update the retained source too")
            let erased=eraserPixels(reload.layers[0])
            precondition(reload.moveNote(0,dx:0,dy:delta) && reload.moveNote(0,dx:0,dy:-delta),"Partly erased overflow text must remain movable")
            precondition(eraserPixels(reload.layers[0]) == erased,"Dragging must not resurrect erased ink")
            reload.active=0;reload.beginSmudge(0);reload.ink=reload.layers[0]
            _=reload.smudge(NSPoint(x:230,y:370),dx:10,dy:0);reload.layers[0]=reload.ink;reload.finishSmudge();reload.active=nil
            let beforeUndo=eraserPixels(reload.sourceLayers[0]!)
            reload.undoSmudge()
            precondition(eraserPixels(reload.sourceLayers[0]!) != beforeUndo && eraserPixels(reload.layers[0]) == erased,"Undo must restore retained source and visible ink together")
            let recoveredSource=eraserPixels(reload.sourceLayers[0]!), recoveredDetail=eraserPixels(reload.sourceDetailedLayers[0]!)
            precondition(reload.washHand(),"Wash must also remove retained overflow sources")
            precondition(reload.sourceLayers.isEmpty && reload.sourceDetailedLayers.isEmpty,"Wash must clear all retained source caches")
            reload.undoWash()
            precondition(eraserPixels(reload.sourceLayers[0]!) == recoveredSource && eraserPixels(reload.sourceDetailedLayers[0]!) == recoveredDetail,"Wash recovery must restore the exact overflow sources")
        }
    }
    print("PASS: Chinese composition at palm and thumb boundaries, automatic wrapping, off-canvas source retention, drag recovery, exact restart and movement, retained-source erasure and undo, wash recovery")
    let multiline = HandView(storage: temp.appendingPathComponent("multiline"))
    let multilineEditor = multiline.makeEditor(frame: NSRect(x: 190, y: 160, width: 100, height: 32))
    precondition(!multilineEditor.drawsBackground && multilineEditor.textContainerInset.width == 0, "Editor must have no background or inset")
    precondition(multiline.handwriting(HandView.defaultFontSize).fontName == "HannotateSC-W5", "Use installed handwriting font")
    multilineEditor.string = "下午交稿然后去拿快递\n记得回复消息"
    multiline.editor = multilineEditor
    multiline.textDidChange(Notification(name: NSText.didChangeNotification))
    precondition(multilineEditor.frame.height > 40, "Editor must grow for wrapped lines")
    multiline.addSubview(multilineEditor)
    let crispEditor = multilineEditor as! SurfaceTextView
    let retinaText = crispEditor.textBitmap(scale: 2)
    precondition(retinaText.pixelsWide == 1280 && retinaText.pixelsHigh == 854 && retinaText.size == multiline.bounds.size, "Retina text must retain point geometry at double pixel density")
    let retinaWarp = multiline.surface.warpDetailed(retinaText, anchor: crispEditor.anchor, angle: crispEditor.angle)
    precondition((320..<420).contains { y in (380..<580).contains { x in retinaWarp.bitmapData![y*retinaWarp.bytesPerRow+x*4+3] > 0 } }, "High resolution glyphs must remain at their hand coordinates")
    try! retinaWarp.representation(using: .png, properties: [:])!.write(to: testOutput.appendingPathComponent("retina-text-preview.png"))
    let standardText = crispEditor.textBitmap(scale: 1)
    let singlePass = multiline.surface.warpDetailed(standardText, anchor: crispEditor.anchor, angle: 0)
    let originalWarp = multiline.surface.warp(standardText)
    precondition(Data(bytes: singlePass.bitmapData!, count: singlePass.bytesPerRow*427) == Data(bytes: originalWarp.bitmapData!, count: originalWarp.bytesPerRow*427), "Combined transform must preserve the original unrotated coordinates")
    try! SelfPreview.make(multiline).write(to: testOutput.appendingPathComponent("live-surface-preview.png"))
    let expectedSavedText = multiline.surface.warpDetailed(crispEditor.textBitmap(scale: 2, editing: false), anchor: crispEditor.anchor, angle: crispEditor.angle)
    let expectedSavedPixels = Data(bytes: expectedSavedText.bitmapData!, count: expectedSavedText.bytesPerRow*expectedSavedText.pixelsHigh)
    multiline.commit()
    precondition(multiline.displayedInk.pixelsWide == 1280 && Data(bytes: multiline.displayedInk.bitmapData!, count: multiline.displayedInk.bytesPerRow*multiline.displayedInk.pixelsHigh) == expectedSavedPixels, "Saving must preserve every preview glyph pixel without the editing caret")
    precondition(multiline.notes[0].height > 40, "Committed bounds must include every line")
    let bitmap = multiline.layers[0]
    let lowerInk = (185..<min(427, Int(multiline.notes[0].rect.maxY))).contains { y in
        (190..<290).contains { x in bitmap.bitmapData![y*bitmap.bytesPerRow+x*4+3] > 0 }
    }
    precondition(lowerInk, "Lower lines must actually render, not just expand bounds")
    let multiPreview = SelfPreview.make(multiline)
    try! multiPreview.write(to: testOutput.appendingPathComponent("multiline-preview.png"))
    let multiReload = HandView(storage: multiline.folder)
    precondition(Data(bytes: multiReload.displayedInk.bitmapData!, count: multiReload.displayedInk.bytesPerRow*multiReload.displayedInk.pixelsHigh) == expectedSavedPixels, "Restart must restore the complete high resolution text exactly")
    precondition(multiReload.notes[0].height == multiline.notes[0].height, "Multiline bounds must persist")
    let undoView = HandView(storage: temp.appendingPathComponent("undo"))
    let undoEditor = undoView.makeEditor(frame: NSRect(x: 190, y: 200, width: 190, height: 32))
    undoEditor.string = "可以撤销"; undoView.editor = undoEditor; undoView.commit()
    let untouchedInk = Data(bytes: undoView.layers[0].bitmapData!, count: undoView.layers[0].bytesPerRow*427)
    undoView.beginSmudge(0); undoView.finishSmudge()
    precondition(undoView.smudgeHistory.isEmpty, "Clicking must not create an undo step")
    let untouchedDetail = Data(bytes:undoView.detailedLayers[0]!.bitmapData!,count:undoView.detailedLayers[0]!.bytesPerRow*854)
    for _ in 0..<2 {
        undoView.beginSmudge(0); undoView.ink = undoView.layers[0]
        undoView.smudge(NSPoint(x: 220, y: 215), dx: 8, dy: 0)
        undoView.layers[0] = undoView.ink
        undoView.notes[0].distance += 200; undoView.notes[0].reversals += 3
        undoView.notes[0].done = true; undoView.finishSmudge()
    }
    precondition(undoView.smudgeHistory.count == 2, "Each stroke must create one step")
    precondition(Data(bytes:undoView.detailedLayers[0]!.bitmapData!,count:undoView.detailedLayers[0]!.bytesPerRow*854) != untouchedDetail, "Rubbing must change high resolution ink too")
    undoView.undoSmudge(); undoView.undoSmudge()
    precondition(Data(bytes:undoView.detailedLayers[0]!.bitmapData!,count:undoView.detailedLayers[0]!.bytesPerRow*854) == untouchedDetail, "Undo must restore high resolution ink exactly")
    precondition(!undoView.notes[0].done && undoView.notes[0].distance == 0 && undoView.notes[0].reversals == 0, "Undo must restore task and rubbing progress")
    precondition(Data(bytes: undoView.layers[0].bitmapData!, count: undoView.layers[0].bytesPerRow*427) == untouchedInk, "Undo must restore exact pigment")
    let undoReload = HandView(storage: undoView.folder)
    precondition(!undoReload.notes[0].done, "Undone completion must persist")
    undoView.undoSmudge()
    let curved = multiline.surface.warp(multiline.ink)
    precondition(Data(bytes: curved.bitmapData!, count: curved.bytesPerRow*427) != Data(bytes: multiline.ink.bitmapData!, count: multiline.ink.bytesPerRow*427), "Height map must visibly deform ink")
    for p in [NSPoint(x: 190, y: 200), NSPoint(x: 280, y: 260), NSPoint(x: 450, y: 240)] {
        let roundTrip = multiline.surface.canonical(multiline.surface.display(p))
        precondition(hypot(roundTrip.x-p.x, roundTrip.y-p.y) < 0.1, "Hit testing must match displaced ink")
    }
    precondition(multiline.surface.heights.max()! > 0.8 && multiline.surface.heights.min()! < 0.1, "Map must have real volume")
    let fingers = HandView(storage: temp.appendingPathComponent("fingers"))
    let examples: [(NSPoint, String, Double)] = [(NSPoint(x: 225,y: 110), "拿快递", 100), (NSPoint(x: 400,y: 174), "回消息", 150), (NSPoint(x: 415,y: 231), "买咖啡", 150), (NSPoint(x: 210,y: 260), "下午交稿", 160)]
    for (origin,text,width) in examples {
        let input = fingers.makeEditor(frame: NSRect(origin: origin, size: NSSize(width: width,height: 32)))
        input.string = text; fingers.editor = input; fingers.commit()
    }
    for i in fingers.notes.indices {
        let detail = fingers.detailedLayers[i]!, anchor = fingers.noteAnchor(fingers.notes[i])
        let angle = fingers.surface.writingAngle(at:anchor)
        let full = fingers.surface.warpDetailed(detail,anchor:anchor,angle:angle,clipped:false)
        let clipped = fingers.surface.warpDetailed(detail,anchor:anchor,angle:angle)
        precondition(Data(bytes:full.bitmapData!,count:full.bytesPerRow*full.pixelsHigh) == Data(bytes:clipped.bitmapData!,count:clipped.bytesPerRow*clipped.pixelsHigh), "Partial rendering must match the complete transform at every writing angle")
    }
    let cachedBefore = Data(bytes:fingers.displayedInk.bitmapData!,count:fingers.displayedInk.bytesPerRow*fingers.displayedInk.pixelsHigh)
    fingers.rebuildInk(changedIndex:0)
    precondition(Data(bytes:fingers.displayedInk.bitmapData!,count:fingers.displayedInk.bytesPerRow*fingers.displayedInk.pixelsHigh) == cachedBefore, "Reusing other note projections must preserve overlap and composition exactly")

    precondition(fingers.surface.writingAngle(at: NSPoint(x:250,y:125)) < -0.8, "Thumb writing must follow its diagonal axis")
    precondition(abs(fingers.surface.writingAngle(at: NSPoint(x:400,y:174))-atan2(-47.0,185.0)) < 0.01, "Index writing follows the finger axis")
    precondition(fingers.moveNote(3,dx:1,dy:0), "A cached note must remain movable")
    let movedCached = Data(bytes:fingers.displayedInk.bitmapData!,count:fingers.displayedInk.bytesPerRow*fingers.displayedInk.pixelsHigh)
    fingers.rebuildInk()
    precondition(Data(bytes:fingers.displayedInk.bitmapData!,count:fingers.displayedInk.bytesPerRow*fingers.displayedInk.pixelsHigh) == movedCached, "An incremental move must match a complete rebuild with multiple notes")
    precondition(fingers.moveNote(3,dx:-1,dy:0), "Returning a cached note must preserve its coordinates")
    let thumb = fingers.notes[0]
    let point = NSPoint(x: thumb.x+40,y:thumb.y+12)
    let projected = fingers.surface.display(fingers.notePoint(point,note:thumb))
    let hit = fingers.pointInNote(fingers.surface.canonical(projected),note:thumb)
    precondition(hypot(hit.x-point.x,hit.y-point.y) < 0.1, "Rotated glyph hit testing must round trip")
    let directionalPreview = SelfPreview.make(fingers)
    try! directionalPreview.write(to: testOutput.appendingPathComponent("finger-direction-preview.png"))
    let reloadedFingers = HandView(storage:fingers.folder)
    precondition(Data(bytes:fingers.displayedInk.bitmapData!,count:fingers.displayedInk.bytesPerRow*427) == Data(bytes:reloadedFingers.displayedInk.bitmapData!,count:reloadedFingers.displayedInk.bytesPerRow*427), "Finger orientation must survive save and restore")
    precondition(fingers.moveNote(3,dx:15,dy:-150), "Palm text must move into the thumb region")
    precondition(fingers.surface.writingAngle(at:fingers.noteAnchor(fingers.notes[3])) < -0.8, "Moved text must adopt thumb direction")
    let thumbBefore = Data(bytes:fingers.layers[0].bitmapData!,count:fingers.layers[0].bytesPerRow*427)
    fingers.active = 0; fingers.beginSmudge(0); fingers.ink = fingers.layers[0]
    fingers.smudge(NSPoint(x:245,y:122),dx:6,dy:0)
    fingers.layers[0] = fingers.ink; fingers.finishSmudge(); fingers.active = nil
    precondition(!fingers.smudgeHistory.isEmpty, "Rotated thumb text must accept rubbing")
    fingers.undoSmudge()
    precondition(Data(bytes:fingers.layers[0].bitmapData!,count:fingers.layers[0].bytesPerRow*427) == thumbBefore, "Undo must restore rotated text ink")
    let clickTest = HandView(storage: temp.appendingPathComponent("clicks"))
    let clickWindow = HandPanel(contentRect: clickTest.bounds, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
    clickWindow.contentView = clickTest
    for point in [NSPoint(x:210,y:240),NSPoint(x:280,y:280),NSPoint(x:230,y:110),NSPoint(x:430,y:175)] {
        clickTest.editor?.removeFromSuperview(); clickTest.editor = nil
        let event = NSEvent.mouseEvent(with:.leftMouseDown,location:clickTest.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:clickWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        clickTest.mouseDown(with:event)
        precondition(clickTest.editor == nil, "Press alone must not enter editing")
        clickTest.mouseUp(with:NSEvent.mouseEvent(with:.leftMouseUp,location:event.locationInWindow,modifierFlags:[],timestamp:0.1,windowNumber:clickWindow.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!)
        precondition(clickTest.editor != nil, "Click must create an editor on palm and fingers")
        if let input = clickTest.editor {
            input.insertText("新待办",replacementRange:NSRange(location:0,length:0))
            precondition(input.string == "新待办", "Real text insertion must work")
            precondition(clickWindow.firstResponder === input, "Editor must receive keyboard focus")
            let previous = clickTest.notes.count
            precondition(clickTest.textView(input, doCommandBy:#selector(NSResponder.insertNewline(_:))), "Return must submit")
            precondition(clickTest.editor == nil && clickTest.notes.count == previous+1, "Return must save a new note")
        }
    }
    let caretEditor = clickTest.makeEditor(frame:NSRect(x:190,y:200,width:190,height:32)) as! SurfaceTextView
    caretEditor.string = "第一行很长很长\n短"
    caretEditor.setSelectedRange(NSRange(location:(caretEditor.string as NSString).length,length:0))
    let caret = caretEditor.caretRect()
    let layout = caretEditor.layoutManager!
    let lastGlyph = layout.numberOfGlyphs-1
    let lastLine = layout.lineFragmentUsedRect(forGlyphAt:lastGlyph,effectiveRange:nil)
    precondition(abs(caret.minX-lastLine.maxX) < 1, "Caret must follow the short final line, not paragraph width")
    precondition(caret.minX < layout.usedRect(for:caretEditor.textContainer!).width/2, "Caret must not jump to the longest line")
    caretEditor.setSelectedRange(NSRange(location:("第一行很长很长\n" as NSString).length,length:0))
    precondition(abs(caretEditor.caretRect().minX) < 1, "Caret at line start must be at that line's start")
    precondition(clickTest.acceptsFirstMouse(for:nil) && caretEditor.acceptsFirstMouse(for:nil), "First click must work without an activation click")
    let switchView = HandView(storage:temp.appendingPathComponent("single-click"))
    let switchWindow = HandPanel(contentRect:switchView.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    switchWindow.contentView = switchView
    func click(_ point:NSPoint) {
        let event = NSEvent.mouseEvent(with:.leftMouseDown,location:switchView.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:switchWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        switchView.mouseDown(with:event)
        switchView.mouseUp(with:NSEvent.mouseEvent(with:.leftMouseUp,location:event.locationInWindow,modifierFlags:[],timestamp:0.1,windowNumber:switchWindow.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!)
    }
    click(NSPoint(x:210,y:230))
    switchView.editor!.insertText("第一条",replacementRange:NSRange(location:0,length:0))
    click(NSPoint(x:290,y:300))
    precondition(switchView.notes.count == 1 && switchView.editor != nil && switchView.editor!.string.isEmpty, "One click elsewhere must save and create next input")
    switchView.commit()
    func gesture(_ type:NSEvent.EventType,_ point:NSPoint,_ time:Double) {
        let event = NSEvent.mouseEvent(with:type,location:switchView.convert(point,to:nil),modifierFlags:[],timestamp:time,windowNumber:switchWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
        switch type { case .leftMouseDown:switchView.mouseDown(with:event); case .leftMouseDragged:switchView.mouseDragged(with:event); default:switchView.mouseUp(with:event) }
    }
    gesture(.leftMouseDown,NSPoint(x:190,y:300),1)
    precondition(switchView.editor == nil && switchView.pointerHeld, "Hold must not create an editor")
    gesture(.leftMouseUp,NSPoint(x:190,y:300),1.8)
    precondition(switchView.editor == nil, "Long press must not create an editor")
    gesture(.leftMouseDown,NSPoint(x:190,y:300),2)
    gesture(.leftMouseDragged,NSPoint(x:220,y:300),2.05)
    gesture(.leftMouseDragged,NSPoint(x:190,y:300),2.1)
    gesture(.leftMouseUp,NSPoint(x:190,y:300),2.15)
    precondition(switchView.editor == nil, "Back-and-forth rubbing must never become a click")
    gesture(.leftMouseDown,NSPoint(x:190,y:300),3)
    gesture(.leftMouseUp,NSPoint(x:191,y:301),3.1)
    precondition(switchView.editor != nil && !switchView.pointerHeld, "A quick click with small jitter must create input")
    switchView.commit()
    let textCount=switchView.notes.count
    let textPixels=Data(bytes:switchView.ink.bitmapData!,count:switchView.ink.bytesPerRow*427)
    for (i,color) in [PenColor.black,.red,.blue].enumerated() {
        switchView.setPen(color)
        let y=280.0+Double(i)*25
        gesture(.leftMouseDown,NSPoint(x:190,y:y),5+Double(i))
        gesture(.leftMouseDragged,NSPoint(x:230,y:y+10),5.1+Double(i))
        gesture(.leftMouseUp,NSPoint(x:260,y:y),5.2+Double(i))
    }
    precondition(switchView.drawingStore.strokes.map(\.color) == [.black,.red,.blue], "Drawing must support all three colors")
    precondition(switchView.editor == nil && switchView.notes.count == textCount, "Pen strokes must not create text notes")
    precondition(Data(bytes:switchView.ink.bitmapData!,count:switchView.ink.bytesPerRow*427) == textPixels, "Drawing must never modify text ink")
    try! SelfPreview.make(switchView).write(to:testOutput.appendingPathComponent("drawing-preview.png"))
    switchView.save()
    let drawingReload=HandView(storage:switchView.folder)
    func allPixels(_ bitmap: NSBitmapImageRep) -> Data {
        Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    precondition(switchView.displayedDrawing.pixelsWide == 1280 && switchView.displayedDrawing.pixelsHigh == 854, "Freehand strokes must retain Retina resolution through surface deformation")
    precondition(allPixels(drawingReload.displayedDrawing) == allPixels(switchView.displayedDrawing), "Saved vector strokes must restore every high resolution pixel")
    let lowDrawing = switchView.drawingStore.bitmap(scale: 1)
    let enlargedDrawing = HandView.blank(scale: 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:enlargedDrawing)
    lowDrawing.draw(in:switchView.bounds)
    NSGraphicsContext.restoreGraphicsState()
    precondition(allPixels(switchView.drawingStore.bitmap()) != allPixels(enlargedDrawing), "High resolution strokes must be drawn from paths rather than enlarged from low resolution pixels")
    try! SelfPreview.make(switchView,scale:2).write(to:testOutput.appendingPathComponent("retina-drawing-preview.png"))
    precondition(drawingReload.drawingStore.strokes.count == 3 && drawingReload.notes.count == textCount, "Drawings and notes must restore separately")
    switchView.drawingStore.clear(); switchView.refreshDrawing()
    precondition(switchView.drawingStore.strokes.isEmpty && switchView.notes.count == textCount, "Clearing drawings must preserve notes")
    switchView.undoCurrent()
    precondition(switchView.drawingStore.strokes.count == 3, "Clearing drawings must be undoable")
    switchView.undoCurrent()
    precondition(switchView.drawingStore.strokes.count == 2 && switchView.notes.count == textCount, "Pen undo must remove just one stroke")
    switchView.setPen(nil)
    precondition(!switchView.penMode && switchView.drawingStore.strokes.count == 2, "Returning to todo mode must preserve artwork")
    let wristPoint=NSPoint(x:switchView.toolButton.frame.midX,y:switchView.toolButton.frame.midY)
    precondition(switchView.hitTest(wristPoint) === switchView.toolButton, "Wrist tool must receive clicks in the requested position")
    precondition(switchView.onSkin(wristPoint), "Wrist tool must sit on skin")
    switchView.setPen(.red)
    precondition(switchView.hitTest(wristPoint) === switchView.toolButton, "Tool entry must remain clickable in drawing mode")
    let toolProbe=ToolActionProbe()
    switchView.toolButton.target=toolProbe; switchView.toolButton.action = #selector(ToolActionProbe.openTools(_:))
    for mode in [PenColor.red,nil,.blue,nil] {
        switchView.setPen(mode)
        precondition(switchView.hitTest(wristPoint) === switchView.toolButton && switchView.toolButton.isEnabled, "Tool remains active after returning to todo mode")
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:switchView.convert(wristPoint,to:nil),modifierFlags:[],timestamp:10,windowNumber:switchWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let up=NSEvent.mouseEvent(with:.leftMouseUp,location:down.locationInWindow,modifierFlags:[],timestamp:10.1,windowNumber:switchWindow.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
        switchView.toolButton.mouseDown(with:down); switchView.toolButton.mouseUp(with:up)
    }
    precondition(toolProbe.count == 4, "Every wrist click must dispatch after mode changes")
    let stickerFolder=temp.appendingPathComponent("sticker-transforms")
    let stickerView=HandView(storage:stickerFolder)
    let noteEditor=stickerView.makeEditor(frame:NSRect(x:190,y:200,width:190,height:32))
    noteEditor.string="图案独立";stickerView.editor=noteEditor;stickerView.commit()
    let noteInkBefore=Data(bytes:stickerView.ink.bitmapData!,count:stickerView.ink.bytesPerRow*427)
    stickerView.addSticker("02-rocket")
    precondition(stickerView.stickerMode && !stickerView.penMode && stickerView.editor == nil, "Adding an element must enter sticker mode")
    precondition(stickerView.stickerStore.transform(dx:20,dy:10,factor:1.5,angle: .pi/4,valid:{stickerView.onSkin(stickerView.surface.display($0))}), "Sticker movement scale and rotation must work")
    let changed=stickerView.stickerStore.selectedItem!
    precondition(changed.x==265 && changed.y==275 && changed.scale==1.5 && abs(changed.rotation-Double.pi/4)<0.001, "Store all transform values")
    precondition(!stickerView.stickerStore.transform(dx:1000,valid:{stickerView.onSkin(stickerView.surface.display($0))}), "Reject moving element off hand")
    stickerView.refreshStickers();stickerView.save()
    let stickerReload=HandView(storage:stickerFolder)
    precondition(stickerView.displayedStickers.pixelsWide == 1280 && stickerView.displayedStickers.pixelsHigh == 854, "Scaled rotated artwork must retain Retina resolution through surface deformation")
    precondition(allPixels(stickerReload.displayedStickers) == allPixels(stickerView.displayedStickers), "Reopening must render transformed artwork from original assets without losing pixels")
    precondition(allPixels(stickerView.displayedStickers).contains { $0 != 0 }, "High resolution transformed artwork must remain visible")
    for (asset,_) in StickerStore.catalog {
        let source = stickerView.stickerStore.bitmaps[asset]!
        precondition(source.pixelsWide >= 600, "Original artwork must cover the maximum 300 point size at Retina density")
    }
    try! SelfPreview.make(stickerView,scale:2).write(to:testOutput.appendingPathComponent("retina-sticker-preview.png"))
    precondition(stickerReload.stickerStore.items==stickerView.stickerStore.items, "Transform values must survive reopening")
    precondition(stickerReload.notes.count==1 && stickerReload.drawingStore.strokes.isEmpty, "Sticker persistence must stay separate")
    precondition(Data(bytes:stickerView.ink.bitmapData!,count:stickerView.ink.bytesPerRow*427)==noteInkBefore, "Manipulating stickers must preserve text ink")
    var inkHit:NSPoint?
    for y in stride(from:220.0,through:330,by:3) { for x in stride(from:200.0,through:330,by:3) {
        let p=NSPoint(x:x,y:y)
        if stickerView.stickerStore.hit(p)==changed.id { inkHit=p;break }
    }; if inkHit != nil {break} }
    precondition(inkHit != nil,"Scaled rotated element must remain selectable by its visible pen lines")
    stickerView.undoCurrent()
    precondition(stickerView.stickerStore.selectedItem?.scale==1, "Undo restores transform as one action")
    stickerView.deleteSticker()
    precondition(stickerView.stickerStore.items.isEmpty,"Selected element can be deleted")
    stickerView.undoCurrent()
    precondition(stickerView.stickerStore.items.count==1,"Element deletion must be undoable")
    stickerView.changeSticker(factor:100)
    precondition(stickerView.stickerStore.selectedItem!.scale==3,"Element scale must stay bounded")
    stickerView.changeSticker(factor:0.00001)
    precondition(stickerView.stickerStore.selectedItem!.scale==0.25,"Minimum element scale must stay usable")
    stickerView.changeSticker(factor:4)
    try! SelfPreview.make(stickerView).write(to:testOutput.appendingPathComponent("sticker-preview.png"))
    let stickerWindow=HandPanel(contentRect:stickerView.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    stickerWindow.contentView=stickerView
    var grab:NSPoint?
    for y in stride(from:220.0,through:310,by:2) { for x in stride(from:210.0,through:290,by:2) {
        let p=NSPoint(x:x,y:y)
        if stickerView.stickerStore.hit(p) != nil { grab=p;break }
    };if grab != nil {break} }
    precondition(grab != nil,"A visible image must provide a drag target")
    let beforeDrag=stickerView.stickerStore.selectedItem!
    func stickerEvent(_ type:NSEvent.EventType,_ p:NSPoint,_ time:Double) {
        let screenPoint=stickerView.surface.display(p)
        let event=NSEvent.mouseEvent(with:type,location:stickerView.convert(screenPoint,to:nil),modifierFlags:[],timestamp:time,windowNumber:stickerWindow.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        switch type {case .leftMouseDown:stickerView.mouseDown(with:event);case .leftMouseDragged:stickerView.mouseDragged(with:event);default:stickerView.mouseUp(with:event)}
    }
    stickerEvent(.leftMouseDown,grab!,20)
    stickerEvent(.leftMouseDragged,NSPoint(x:grab!.x+10,y:grab!.y+6),20.1)
    stickerEvent(.leftMouseDragged,NSPoint(x:grab!.x+16,y:grab!.y+8),20.2)
    stickerEvent(.leftMouseUp,NSPoint(x:grab!.x+16,y:grab!.y+8),20.3)
    precondition(abs(stickerView.stickerStore.selectedItem!.x-beforeDrag.x-16)<0.1,"Dragging a transformed element must follow pointer")
    precondition(stickerView.editor == nil && !stickerView.pointerHeld,"Element drag must not open text editing")
    stickerView.undoCurrent()
    precondition(abs(stickerView.stickerStore.selectedItem!.x-beforeDrag.x)<0.1,"Whole drag must undo in one step")
    let cleanView=HandView(storage:temp.appendingPathComponent("wash"))
    let cleanInput=cleanView.makeEditor(frame:NSRect(x:190,y:200,width:190,height:32))
    cleanInput.string="待洗掉";cleanView.editor=cleanInput;cleanView.commit()
    cleanView.notes[0].done=true
    cleanView.ink=cleanView.layers[0];cleanView.smudge(NSPoint(x:210,y:215),dx:8,dy:0);cleanView.layers[0]=cleanView.ink;cleanView.rebuildInk()
    cleanView.drawingStore.begin(NSPoint(x:220,y:300),color:.red);cleanView.drawingStore.append(NSPoint(x:240,y:310),inside:true);cleanView.drawingStore.finish()
    cleanView.addSticker("01-cat")
    precondition(cleanView.washHand(),"Wash must clear all content kinds")
    precondition(!cleanView.hasHandContent && cleanView.notes.isEmpty && cleanView.layers.isEmpty,"Wash removes task records and all text layers")
    for bitmap in [cleanView.ink,cleanView.displayedInk,cleanView.displayedDrawing,cleanView.displayedStickers] {
        let bytes=Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        precondition(bytes.allSatisfy{$0==0},"Wash must leave absolutely no pigment or smudge residue")
    }
    precondition(!cleanView.drawingStore.canUndo && !cleanView.stickerStore.canUndo && cleanView.smudgeHistory.isEmpty,"Old histories cannot resurrect individual remnants")
    let cleanReload=HandView(storage:cleanView.folder)
    precondition(!cleanReload.hasHandContent && cleanReload.canUndoWash,"Clean hand and recovery must survive restart")
    cleanReload.undoCurrent()
    precondition(cleanReload.notes.count==1 && cleanReload.notes[0].done && cleanReload.drawingStore.strokes.count==1 && cleanReload.stickerStore.items.count==1,"Undo wash restores all content kinds together")
    precondition(!cleanReload.canUndoWash,"Wash recovery must be consumed after restoration")
    precondition(cleanReload.washHand(),"Hand can be washed again")
    precondition(!cleanReload.washHand(),"Washing a clean hand cannot overwrite recovery")
    print("PASS: freehand eraser partial removal, live replay equality, isolation, persistence, grouped undo, repaint and empty gesture handling, precise clean continuous erasing, no pigment spreading, gesture completion persistence isolation and exact undo, partial rendering matches full rendering and cached composition, high resolution vector drawing and artwork persistence, high resolution save and restart pixel equality, high resolution movement and smudge undo, wash all layers and zero residue, persistent wash and recovery, element drag gesture and grouped undo, element move scale rotation, element hit testing persistence isolation and undo, repeat wrist activation after mode changes, wrist tool hit testing, three pen colors, drawing isolation, drawing persistence and undo, click vs long press and rubbing, short-line caret, first-click focus, single-click input switching, click-create typing-focus and return-save, finger direction, rotated hit testing and persistence, height-map deformation, inverse hit testing, multi-step smudge undo, completion restoration, undo persistence, handwriting, transparent editor, multiline growth and rendering, edge retrigger prevention, hover stability, immediate exit, overlap isolation, legacy migration, move, bounds, position persistence, ink preservation, input, pigment displacement, persistent completion, ink residue restoration")
    try? FileManager.default.removeItem(at: temp)
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
