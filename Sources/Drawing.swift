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
}
final class DrawingStore {
    private(set) var strokes: [PenStroke] = []
    private var history: [[PenStroke]] = []
    private(set) var drawing = false
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
    func append(_ p:NSPoint,inside:Bool) {
        guard drawing,!strokes.isEmpty else { return }
        if inside { strokes[strokes.count-1].points.append(PenPoint(p)) }
        else if strokes.last!.points.last! != nil { strokes[strokes.count-1].points.append(nil) }
    }
    func finish() { drawing=false; save() }
    func undo() {
        guard canUndo,let previous=history.popLast() else { return }
        strokes=previous; save()
    }
    func clear() {
        guard !drawing,!strokes.isEmpty else { return }
        snapshot(); strokes=[]; save()
    }
    func replaceAll(_ content:[PenStroke]) { strokes=content;history=[];drawing=false;save() }
    func save() { if let data=try? JSONEncoder().encode(strokes) { try? data.write(to:url,options:.atomic) } }
    func bitmap() -> NSBitmapImageRep {
        let bitmap=HandView.blank()
        NSGraphicsContext.saveGraphicsState()
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        context.cgContext.translateBy(x:0,y:427); context.cgContext.scaleBy(x:1,y:-1)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        for stroke in strokes {
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
