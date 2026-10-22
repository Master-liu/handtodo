import AppKit

struct PalmSticker: Codable, Equatable {
    var id=UUID()
    var asset:String
    var x=245.0, y=265.0, scale=1.0, rotation=0.0
    var center:NSPoint { NSPoint(x:x,y:y) }
}
final class StickerStore {
    static let catalog=[("01-cat","趴线小猫"),("02-rocket","迷你火箭"),("03-ufo","飞碟捞星星"),("04-boat","漂流纸船"),("05-coffee","跑步咖啡杯")]
    private(set) var items:[PalmSticker]=[]
    private var history:[[PalmSticker]]=[]
    var selected:UUID?
    let url:URL
    let images:[String:NSImage]
    let bitmaps:[String:NSBitmapImageRep]
    var canUndo:Bool { !history.isEmpty }
    var selectedItem:PalmSticker? { items.first{$0.id==selected} }
    init(folder:URL) {
        url=folder.appendingPathComponent("stickers.json")
        var images:[String:NSImage]=[:], bitmaps:[String:NSBitmapImageRep]=[:]
        for (name,_) in Self.catalog {
            let source=Bundle.main.url(forResource:name,withExtension:"png",subdirectory:"Doodles")!
            let data=try! Data(contentsOf:source)
            images[name]=NSImage(data:data)!; bitmaps[name]=NSBitmapImageRep(data:data)!
        }
        self.images=images; self.bitmaps=bitmaps
        if let data=try? Data(contentsOf:url),let saved=try? JSONDecoder().decode([PalmSticker].self,from:data) {
            items=saved.filter{images[$0.asset] != nil && $0.x.isFinite && $0.y.isFinite && $0.scale.isFinite && $0.rotation.isFinite}.map {
                var s=$0; s.scale=max(0.25,min(3,s.scale)); return s
            }
        }
    }
    private func snapshot() { history.append(items); if history.count>30 { history.removeFirst() } }
    func add(_ asset:String) {
        guard images[asset] != nil else { return }
        snapshot(); let item=PalmSticker(asset:asset); items.append(item); selected=item.id; save()
    }
    @discardableResult func transform(dx:Double=0,dy:Double=0,factor:Double=1,angle:Double=0,record:Bool=true,valid:(NSPoint)->Bool) -> Bool {
        guard let index=items.firstIndex(where:{$0.id==selected}),dx.isFinite,dy.isFinite,factor.isFinite,angle.isFinite else { return false }
        var item=items[index]
        item.x+=dx; item.y+=dy; item.scale=max(0.25,min(3,item.scale*factor))
        item.rotation=(item.rotation+angle).truncatingRemainder(dividingBy:2 * .pi)
        guard valid(item.center),item != items[index] else { return false }
        if record { snapshot() }; items[index]=item; save(); return true
    }
    func delete() {
        guard let index=items.firstIndex(where:{$0.id==selected}) else { return }
        snapshot(); items.remove(at:index); selected=nil; save()
    }
    func undo() {
        guard let previous=history.popLast() else { return }
        items=previous
        if !items.contains(where:{$0.id==selected}) { selected=items.last?.id }
        save()
    }
    func replaceAll(_ content:[PalmSticker]) { items=content;history=[];selected=nil;save() }
    func save() { if let data=try? JSONEncoder().encode(items) { try? data.write(to:url,options:.atomic) } }
    func size(_ sticker:PalmSticker) -> NSSize {
        let b=bitmaps[sticker.asset]!
        return NSSize(width:100*sticker.scale,height:100*Double(b.pixelsHigh)/Double(b.pixelsWide)*sticker.scale)
    }
    func hit(_ point:NSPoint) -> UUID? {
        for item in items.reversed() {
            let dx=point.x-item.x,dy=point.y-item.y,c=cos(item.rotation),s=sin(item.rotation),size=size(item)
            let u=(dx*c+dy*s)/size.width+0.5,v=(-dx*s+dy*c)/size.height+0.5
            guard u>=0,u<1,v>=0,v<1 else { continue }
            let b=bitmaps[item.asset]!,x=Int(u*Double(b.pixelsWide)),y=Int(v*Double(b.pixelsHigh))
            // A small tolerance around thin pen lines makes miniature artwork easier to grab.
            let radius=max(2,Int(5/size.width*Double(b.pixelsWide)))
            for py in stride(from:max(0,y-radius),through:min(b.pixelsHigh-1,y+radius),by:max(1,radius/3)) {
                for px in stride(from:max(0,x-radius),through:min(b.pixelsWide-1,x+radius),by:max(1,radius/3)) {
                    if (b.colorAt(x:px,y:py)?.alphaComponent ?? 0)>0.08 { return item.id }
                }
            }
        }
        return nil
    }
    func bitmap(scale: Int = 2) -> NSBitmapImageRep {
        let bitmap=HandView.blank(scale: scale)
        NSGraphicsContext.saveGraphicsState()
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        context.cgContext.interpolationQuality = .high
        context.cgContext.setShouldAntialias(true)
        context.cgContext.translateBy(x:0,y:427);context.cgContext.scaleBy(x:1,y:-1)
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        for item in items {
            NSGraphicsContext.saveGraphicsState()
            context.cgContext.translateBy(x:item.x,y:item.y);context.cgContext.rotate(by:item.rotation)
            let size=size(item)
            images[item.asset]!.draw(in:NSRect(x:-size.width/2,y:-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState();return bitmap
    }
}
