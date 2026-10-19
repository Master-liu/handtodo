import AppKit
// Hand-authored anatomical approximation for this exact fixed illustration, not image luminance.
let width = 640, height = 427
let map = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8)!
func mound(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ strength: Double) -> Double {
    let distance = pow((x-cx)/rx,2)+pow((y-cy)/ry,2)
    return strength*exp(-distance*1.8)
}
func finger(_ x: Double, _ y: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ radius: Double) -> Double {
    let vx = bx-ax, vy = by-ay
    let t = max(0,min(1,((x-ax)*vx+(y-ay)*vy)/(vx*vx+vy*vy)))
    let dx = x-(ax+t*vx), dy = y-(ay+t*vy)
    return 0.65*exp(-(dx*dx+dy*dy)/(radius*radius))
}
for y in 0..<height { for x in 0..<width {
    let px = Double(x), py = Double(y)
    var h = mound(px,py,250,252,155,150,0.78)
    h = max(h,mound(px,py,170,295,90,108,0.92))
    h = max(h,mound(px,py,315,300,65,105,0.57))
    h = max(h,finger(px,py,210,150,275,35,30))
    h = max(h,finger(px,py,355,182,540,135,27))
    h = max(h,finger(px,py,380,240,590,207,26))
    h = max(h,finger(px,py,380,300,580,288,26))
    h = max(h,finger(px,py,370,360,515,385,23))
    h = max(h,mound(px,py,35,300,145,85,0.45))
    // A shallow crease through the palm; broad enough to preserve legibility.
    h -= 0.055*exp(-pow((py-(329-0.42*px))/5,2))*exp(-pow((px-245)/100,2))
    map.bitmapData![y*width+x] = UInt8(max(0,min(255,(h*255).rounded())))
} }
try map.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
