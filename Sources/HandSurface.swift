import AppKit

// Surface coordinates are kept separate from display pixels. The saved ink stays unwarped.
final class HandSurface {
    static let width = 640, height = 427
    static let shared = HandSurface(url: Bundle.main.url(forResource: "hand-height", withExtension: "png")!)
    let skin: [Bool]
    let heights: [Double]
    let sourceX: [Double]
    let sourceY: [Double]
    let inverseDisplacement: NSRect
    init(url: URL) {
        let map = NSBitmapImageRep(data: try! Data(contentsOf: url))!
        precondition(map.pixelsWide == Self.width && map.pixelsHigh == Self.height)
        var values = [Double](repeating: 0, count: Self.width*Self.height)
        for y in 0..<Self.height { for x in 0..<Self.width {
            values[y*Self.width+x] = Double(map.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent)
        } }
        heights = values
        let hand = NSBitmapImageRep(data: try! Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("hand.png")))!
        var coverage = [Bool](repeating: false, count: values.count)
        for y in 0..<Self.height { for x in 0..<Self.width {
            coverage[y*Self.width+x] = (hand.colorAt(x: min(hand.pixelsWide-1,x*hand.pixelsWide/640), y: min(hand.pixelsHigh-1,y*hand.pixelsHigh/427))?.alphaComponent ?? 0) > 0.95
        } }
        skin = coverage
        var xs = [Double](), ys = [Double]()
        xs.reserveCapacity(values.count); ys.reserveCapacity(values.count)
        for y in 0..<Self.height { for x in 0..<Self.width {
            let p = Self.inverse(NSPoint(x: x, y: y), values)
            xs.append(p.x); ys.append(p.y)
        } }
        sourceX = xs; sourceY = ys
        let dx = xs.enumerated().map { $0.element-Double($0.offset % Self.width) }
        let dy = ys.enumerated().map { $0.element-Double($0.offset / Self.width) }
        inverseDisplacement = NSRect(x:dx.min()!-1,y:dy.min()!-1,width:dx.max()!-dx.min()!+2,height:dy.max()!-dy.min()!+2)
    }
    private static func height(_ p: NSPoint, _ values: [Double]) -> Double {
        let px = min(639.0, max(0, p.x)), py = min(426.0, max(0, p.y))
        let x = Int(px), y = Int(py), fx = px-Double(x), fy = py-Double(y)
        func v(_ dx: Int, _ dy: Int) -> Double { values[min(426,y+dy)*640+min(639,x+dx)] }
        return v(0,0)*(1-fx)*(1-fy)+v(1,0)*fx*(1-fy)+v(0,1)*(1-fx)*fy+v(1,1)*fx*fy
    }
    private static func forward(_ p: NSPoint, _ values: [Double]) -> NSPoint {
        let h = height(p, values)
        let gradient = (height(NSPoint(x: p.x+2, y: p.y), values)-height(NSPoint(x: p.x-2, y: p.y), values))/4
        return NSPoint(x: p.x-gradient*70, y: p.y-h*18)
    }
    private static func inverse(_ p: NSPoint, _ values: [Double]) -> NSPoint {
        var q = p
        for _ in 0..<10 {
            let mapped = forward(q, values)
            q.x += p.x-mapped.x; q.y += p.y-mapped.y
        }
        return q
    }
    func display(_ p: NSPoint) -> NSPoint { Self.forward(p, heights) }
    func canonical(_ p: NSPoint) -> NSPoint { Self.inverse(p, heights) }
    func warp(_ bitmap: NSBitmapImageRep, mask: NSBitmapImageRep? = nil) -> NSBitmapImageRep {
        let result = HandView.blank(), input = bitmap.bitmapData!, output = result.bitmapData!
        for y in 0..<427 { for x in 0..<640 {
            guard skin[y*640+x] else { continue }
            let index = y*640+x, sx = sourceX[index], sy = sourceY[index]
            guard sx >= 0, sx < 639, sy >= 0, sy < 426 else { continue }
            if let mask, mask.bitmapData![y*mask.bytesPerRow+x*4+3] < 240 { continue }
            let ix = Int(sx), iy = Int(sy), fx = sx-Double(ix), fy = sy-Double(iy)
            let offset = iy*bitmap.bytesPerRow+ix*4
            let a = (1-fx)*(1-fy), b = fx*(1-fy), c = (1-fx)*fy, d = fx*fy
            for channel in 0..<4 {
                let value = Double(input[offset+channel])*a+Double(input[offset+4+channel])*b+Double(input[offset+bitmap.bytesPerRow+channel])*c+Double(input[offset+bitmap.bytesPerRow+4+channel])*d
                output[y*result.bytesPerRow+x*4+channel] = UInt8(min(255,max(0,value.rounded())))
            }
        } }
        return result
    }
    static func inkBounds(_ bitmap: NSBitmapImageRep) -> NSRect {
        let pixels = bitmap.bitmapData!, scale = Double(bitmap.pixelsWide)/Double(Self.width)
        var left = bitmap.pixelsWide, top = bitmap.pixelsHigh, right = -1, bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            let row = y*bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide where pixels[row+x*4+3] != 0 {
                left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
            }
        }
        guard right >= left else { return .zero }
        return NSRect(x:Double(left)/scale,y:Double(top)/scale,width:Double(right-left+1)/scale,height:Double(bottom-top+1)/scale)
    }
    func displayBounds(_ source: NSRect, anchor: NSPoint, angle: Double, scale: Int) -> NSRect {
        guard !source.isEmpty else { return .zero }
        let padded = source.insetBy(dx:-1/Double(scale),dy:-1/Double(scale))
        let corners = [NSPoint(x:padded.minX,y:padded.minY),NSPoint(x:padded.maxX,y:padded.minY),NSPoint(x:padded.minX,y:padded.maxY),NSPoint(x:padded.maxX,y:padded.maxY)].map { orient($0,anchor:anchor,angle:angle) }
        let left = corners.map(\.x).min()!-inverseDisplacement.maxX
        let top = corners.map(\.y).min()!-inverseDisplacement.maxY
        let right = corners.map(\.x).max()!-inverseDisplacement.minX
        let bottom = corners.map(\.y).max()!-inverseDisplacement.minY
        return NSRect(x:floor(left*Double(scale)),y:floor(top*Double(scale)),width:ceil(right*Double(scale))-floor(left*Double(scale)),height:ceil(bottom*Double(scale))-floor(top*Double(scale))).intersection(NSRect(x:0,y:0,width:Self.width*scale,height:Self.height*scale))
    }
    // Sample the original artwork once, combining optional rotation and surface deformation.
    // Bitmap dimensions follow the display scale; all geometry remains in hand points.
    func warpDetailed(_ bitmap: NSBitmapImageRep, anchor: NSPoint = .zero, angle: Double = 0, sourceBounds: NSRect? = nil, clipped: Bool = true) -> NSBitmapImageRep {
        let scale = bitmap.pixelsWide / Self.width
        precondition(scale >= 1 && bitmap.pixelsHigh == Self.height * scale)
        let result = HandView.blank(scale: scale)
        let input = bitmap.bitmapData!, output = result.bitmapData!
        let c = cos(angle), s = sin(angle)
        let region = clipped ? displayBounds(sourceBounds ?? Self.inkBounds(bitmap),anchor:anchor,angle:angle,scale:scale) : NSRect(x:0,y:0,width:result.pixelsWide,height:result.pixelsHigh)
        guard !region.isEmpty else { return result }
        for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
            let px = Double(x)/Double(scale), py = Double(y)/Double(scale)
            let mx = Int(px), my = Int(py)
            guard skin[my*Self.width+mx] else { continue }
            let fx = px-Double(mx), fy = py-Double(my)
            func mapped(_ values: [Double]) -> Double {
                let i = my*Self.width+mx, right = min(mx+1,Self.width-1)-mx
                let below = (min(my+1,Self.height-1)-my)*Self.width
                return values[i]*(1-fx)*(1-fy)+values[i+right]*fx*(1-fy)
                    + values[i+below]*(1-fx)*fy+values[i+below+right]*fx*fy
            }
            let dx = mapped(sourceX)-anchor.x, dy = mapped(sourceY)-anchor.y
            let sx = (anchor.x+dx*c+dy*s)*Double(scale)
            let sy = (anchor.y-dx*s+dy*c)*Double(scale)
            guard sx >= 0, sx < Double(bitmap.pixelsWide-1), sy >= 0, sy < Double(bitmap.pixelsHigh-1) else { continue }
            let ix = Int(sx), iy = Int(sy), tx = sx-Double(ix), ty = sy-Double(iy)
            let offset = iy*bitmap.bytesPerRow+ix*4, dest = y*result.bytesPerRow+x*4
            for channel in 0..<4 {
                let value = Double(input[offset+channel])*(1-tx)*(1-ty)
                    + Double(input[offset+4+channel])*tx*(1-ty)
                    + Double(input[offset+bitmap.bytesPerRow+channel])*(1-tx)*ty
                    + Double(input[offset+bitmap.bytesPerRow+4+channel])*tx*ty
                output[dest+channel] = UInt8(min(255,max(0,value.rounded())))
            }
        } }
        return result
    }

}

final class SurfaceTextView: NSTextView {
    var surface: HandSurface?
    private var caretVisible = true
    var anchor: NSPoint { NSPoint(x: frame.minX+textContainerOrigin.x, y: frame.minY+textContainerOrigin.y) }
    var angle: Double { surface?.writingAngle(at: anchor) ?? 0 }
    func refreshSurface() { superview?.needsDisplay = true }
    private func surfaceEvent(_ event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let local = convert(event.locationInWindow, from: nil)
        let source = surface.unorient(surface.canonical(NSPoint(x: frame.minX+local.x, y: frame.minY+local.y)), anchor: anchor, angle: angle)
        let location = convert(NSPoint(x: source.x-frame.minX, y: source.y-frame.minY), to: nil)
        return NSEvent.mouseEvent(with: event.type, location: location, modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) ?? event
    }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: surfaceEvent(event)) }
    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: surfaceEvent(event)) }
    override func draw(_ dirtyRect: NSRect) { }
    func drawOnHand() {
        guard let surface else { return }
        let scale = max(1, Int(ceil(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)))
        let bitmap = textBitmap(scale: scale)
        let image = NSImage(size: NSSize(width: 640, height: 427))
        image.addRepresentation(surface.warpDetailed(bitmap, anchor: anchor, angle: angle))
        image.draw(in: NSRect(x: 0, y: 0, width: 640, height: 427), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    func textBitmap(scale: Int, editing: Bool = true) -> NSBitmapImageRep {
        let bitmap = HandView.blank(scale: scale)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
        ctx.cgContext.translateBy(x: 0, y: 427); ctx.cgContext.scaleBy(x: 1, y: -1)
        ctx.cgContext.setShouldAntialias(true)
        ctx.cgContext.setShouldSmoothFonts(false)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        guard let manager = layoutManager, let container = textContainer else { NSGraphicsContext.restoreGraphicsState(); return bitmap }
        manager.ensureLayout(for: container)
        let origin = anchor, range = manager.glyphRange(for: container)
        if editing { manager.drawBackground(forGlyphRange: range, at: origin) }
        manager.drawGlyphs(forGlyphRange: range, at: origin)
        if editing && caretVisible && selectedRange().length == 0 {
            var caret = caretRect()
            caret.origin.x += origin.x; caret.origin.y += origin.y
            insertionPointColor.setFill(); caret.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    // A local, pixel-aligned source retains lines outside the fixed hand canvas.
    var contentOrigin: NSPoint { NSPoint(x: floor(anchor.x)-2, y: floor(anchor.y)-2) }
    func contentBitmap(scale: Int) -> NSBitmapImageRep {
        guard let manager = layoutManager, let container = textContainer else { return HandView.blank(scale: scale) }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let origin = NSPoint(x: anchor.x-contentOrigin.x, y: anchor.y-contentOrigin.y)
        let size = NSSize(width: ceil(max(container.containerSize.width, used.maxX)+origin.x+2), height: ceil(used.maxY+origin.y+2))
        let bitmap = HandView.blank(size: size, scale: scale)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
        ctx.cgContext.translateBy(x: 0, y: size.height); ctx.cgContext.scaleBy(x: 1, y: -1)
        ctx.cgContext.setShouldAntialias(true); ctx.cgContext.setShouldSmoothFonts(false)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func caretRect() -> NSRect {
        guard let manager = layoutManager, let container = textContainer else { return .zero }
        manager.ensureLayout(for: container)
        let length = (string as NSString).length, index = min(selectedRange().location,length)
        let height = (font?.ascender ?? 16)-(font?.descender ?? -4)
        if length == 0 { return NSRect(x:0,y:0,width:1.2,height:height) }
        if index == length && string.hasSuffix("\n") {
            return NSRect(x:manager.extraLineFragmentRect.minX,y:manager.extraLineFragmentRect.minY,width:1.2,height:height)
        }
        let character = min(index,length-1)
        let glyph = manager.glyphIndexForCharacter(at:character)
        let line = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        let count = manager.getLineFragmentInsertionPoints(forCharacterAt:character,alternatePositions:false,inDisplayOrder:false,positions:nil,characterIndexes:nil)
        if count > 0 {
            var positions = [CGFloat](repeating:0,count:count)
            var indexes = [Int](repeating:0,count:count)
            _ = manager.getLineFragmentInsertionPoints(forCharacterAt:character,alternatePositions:false,inDisplayOrder:false,positions:&positions,characterIndexes:&indexes)
            if let i = indexes.firstIndex(of:index) { return NSRect(x:positions[i],y:line.minY,width:1.2,height:height) }
        }
        let used = manager.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil)
        let x = index == length ? used.maxX : line.minX+manager.location(forGlyphAt:glyph).x
        return NSRect(x:x,y:line.minY,width:1.2,height:height)
    }
    func editingContains(_ canonical: NSPoint) -> Bool {
        guard let manager = layoutManager, let container = textContainer else { return false }
        manager.ensureLayout(for:container)
        var used = manager.usedRect(for:container)
        used.size.width = max(26,used.width); used.size.height = max(24,used.height)
        return used.offsetBy(dx:anchor.x,dy:anchor.y).insetBy(dx:-5,dy:-4).contains(canonical)
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard surface != nil else { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag); return }
        caretVisible = flag; refreshSurface()
    }
}

extension HandSurface {
    // Finger axes match the fixed illustration in hand-space coordinates (y points down).
    func writingAngle(at p: NSPoint) -> Double {
        if p.y < 164 && p.x > 170 && p.x < 345 { return atan2(-116.0, 88.0) }
        if p.x > 360 {
            let fingers: [(Double,Double,Double,Double)] = [(355,182,540,135),(380,240,590,207),(380,300,580,288),(370,360,515,385)]
            var nearest=Double.greatestFiniteMagnitude, angle=0.0
            for (ax,ay,bx,by) in fingers {
                let dx=bx-ax, dy=by-ay
                let t=max(0,min(1,((p.x-ax)*dx+(p.y-ay)*dy)/(dx*dx+dy*dy)))
                let distance=hypot(p.x-(ax+t*dx),p.y-(ay+t*dy))
                if distance<nearest { nearest=distance; angle=atan2(dy,dx) }
            }
            return angle
        }
        return 0
    }
    func orient(_ p: NSPoint, anchor: NSPoint, angle: Double) -> NSPoint {
        let x = p.x-anchor.x, y = p.y-anchor.y
        return NSPoint(x: anchor.x+x*cos(angle)-y*sin(angle), y: anchor.y+x*sin(angle)+y*cos(angle))
    }
    func unorient(_ p: NSPoint, anchor: NSPoint, angle: Double) -> NSPoint { orient(p, anchor: anchor, angle: -angle) }
    func oriented(_ bitmap: NSBitmapImageRep, anchor: NSPoint, angle: Double) -> NSBitmapImageRep {
        if abs(angle) < 0.0001 { return bitmap }
        let result = HandView.blank(), input = bitmap.bitmapData!, output = result.bitmapData!
        let c = cos(angle), s = sin(angle)
        for y in 0..<427 { for x in 0..<640 {
            let dx = Double(x)-anchor.x, dy = Double(y)-anchor.y
            let sx = anchor.x+dx*c+dy*s, sy = anchor.y-dx*s+dy*c
            guard sx >= 0, sx < 639, sy >= 0, sy < 426 else { continue }
            let ix = Int(sx), iy = Int(sy), fx = sx-Double(ix), fy = sy-Double(iy)
            let o = iy*bitmap.bytesPerRow+ix*4, dest = y*result.bytesPerRow+x*4
            for channel in 0..<4 {
                let value = Double(input[o+channel])*(1-fx)*(1-fy)+Double(input[o+4+channel])*fx*(1-fy)+Double(input[o+bitmap.bytesPerRow+channel])*(1-fx)*fy+Double(input[o+bitmap.bytesPerRow+4+channel])*fx*fy
                output[dest+channel] = UInt8(min(255,max(0,value.rounded())))
            }
        } }
        return result
    }
}
