import AppKit

enum PenColor: String, Codable {
    case black, red, blue
    var ink: NSColor {
        switch self {
        case .black: return NSColor(calibratedWhite:0.10,alpha:0.95)
        case .red: return NSColor(calibratedRed:0.82,green:0.16,blue:0.18,alpha:0.95)
        case .blue: return NSColor(calibratedRed:0.12,green:0.28,blue:0.70,alpha:0.95)
        }
    }
}
struct PenPoint: Codable {
    let x: Double; let y: Double
    var point: NSPoint { NSPoint(x:x,y:y) }
    init(_ p:NSPoint) { x=p.x; y=p.y }
}
struct PenStroke: Codable {
    let color: PenColor
    var points: [PenPoint?]
    var eraser: Bool? = nil
}
final class DrawingStore {
    private(set) var strokes: [PenStroke] = []
    private var history: [[PenStroke]] = []
    private(set) var drawing = false
    private var erasePreview: NSBitmapImageRep?
    private var eraseBefore: [PenStroke]?
    private var eraseOriginal: Data?
    let url: URL
    var canUndo: Bool { !history.isEmpty && !drawing }
    init(folder:URL) {
        url = folder.appendingPathComponent("drawing.json")
        if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([PenStroke].self,from:data) { strokes=saved }
    }
    private func snapshot() { history.append(strokes); if history.count>30 { history.removeFirst() } }
    func begin(_ p:NSPoint,color:PenColor) {
        guard !drawing else { return }
        snapshot(); strokes.append(PenStroke(color:color,points:[PenPoint(p)])); drawing=true
    }
    func beginErasing(_ p: NSPoint) {
        guard !drawing else { return }
        let preview = bitmap()
        eraseBefore=strokes
        eraseOriginal=Data(bytes:preview.bitmapData!,count:preview.bytesPerRow*preview.pixelsHigh)
        strokes.append(PenStroke(color:.black,points:[PenPoint(p)],eraser:true));drawing=true
        erasePreview=preview
        updateErasePreview(from:nil,to:p)
    }
    private static func eraseSegment(from start: NSPoint?, to end: NSPoint, context: CGContext) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setStrokeColor(NSColor.black.cgColor);context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(HandView.eraserRadius*2);context.setLineCap(.round)
        if let start, hypot(end.x-start.x,end.y-start.y) > 0.0001 {
            context.move(to:start);context.addLine(to:end);context.strokePath()
        } else {
            context.fillEllipse(in:NSRect(x:end.x-HandView.eraserRadius,y:end.y-HandView.eraserRadius,width:HandView.eraserRadius*2,height:HandView.eraserRadius*2))
        }
        context.restoreGState()
    }
    private func updateErasePreview(from start: NSPoint?, to end: NSPoint) {
        guard let bitmap=erasePreview else { return }
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!.cgContext
        context.translateBy(x:0,y:427);context.scaleBy(x:1,y:-1)
        context.setShouldAntialias(true)
        Self.eraseSegment(from:start,to:end,context:context)
    }
    func append(_ p:NSPoint,inside:Bool) {
        guard drawing,!strokes.isEmpty else { return }
        if inside {
            if strokes.last!.eraser == true { updateErasePreview(from:strokes.last!.points.last.flatMap { $0?.point },to:p) }
            strokes[strokes.count-1].points.append(PenPoint(p))
        }
        else if strokes.last!.points.last! != nil { strokes[strokes.count-1].points.append(nil) }
    }
    func finish() {
        if let before=eraseBefore, let preview=erasePreview, let original=eraseOriginal {
            if Data(bytes:preview.bitmapData!,count:preview.bytesPerRow*preview.pixelsHigh) == original { strokes=before }
            else { history.append(before);if history.count>30 { history.removeFirst() } }
        }
        drawing=false;erasePreview=nil;eraseBefore=nil;eraseOriginal=nil;save()
    }
    func undo() {
        guard canUndo,let previous=history.popLast() else { return }
        strokes=previous;erasePreview=nil;save()
    }
    func clear() {
        guard !drawing,!strokes.isEmpty else { return }
        snapshot(); strokes=[];erasePreview=nil;save()
    }
    func replaceAll(_ content:[PenStroke]) { strokes=content;history=[];drawing=false;erasePreview=nil;eraseBefore=nil;eraseOriginal=nil;save() }
    func save() { if let data=try? JSONEncoder().encode(strokes) { try? data.write(to:url,options:.atomic) } }
    func bitmap(scale: Int = 2) -> NSBitmapImageRep {
        if scale == 2, let preview=erasePreview { return preview }
        let bitmap=HandView.blank(scale: scale)
        NSGraphicsContext.saveGraphicsState()
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        context.cgContext.setShouldAntialias(true)
        context.cgContext.translateBy(x:0,y:427); context.cgContext.scaleBy(x:1,y:-1)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        for stroke in strokes {
            if stroke.eraser == true {
                var previous: NSPoint?
                for sample in stroke.points {
                    guard let sample else { previous=nil;continue }
                    Self.eraseSegment(from:previous,to:sample.point,context:context.cgContext)
                    previous=sample.point
                }
                continue
            }
            stroke.color.ink.setStroke(); stroke.color.ink.setFill()
            let path=NSBezierPath(); path.lineWidth=2.2; path.lineCapStyle = .round; path.lineJoinStyle = .round
            var started=false
            for sample in stroke.points {
                guard let sample else { started=false; continue }
                if started { path.line(to:sample.point) }
                else {
                    path.move(to:sample.point); NSBezierPath(ovalIn:NSRect(x:sample.x-1.1,y:sample.y-1.1,width:2.2,height:2.2)).fill()
                    started=true
                }
            }
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
