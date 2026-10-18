import AppKit
// Two crops of the same menu bar, side by side: Roost's items are separated
// by another app's icon, and a README of Roost should not advertise it.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let left = NSImage(contentsOfFile: args[0]),
      let right = NSImage(contentsOfFile: args[1]) else { exit(1) }
// Pixels, not points: these crops are 2x, and NSImage.size reports points --
// sizing the canvas from it halved the strip.
func pixels(_ image: NSImage) -> CGSize {
    guard let rep = image.representations.first else { return image.size }
    return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
}
let leftSize = pixels(left), rightSize = pixels(right)
let gap: CGFloat = 26
let h = max(leftSize.height, rightSize.height)
let w = leftSize.width + gap + rightSize.width
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
left.draw(in: NSRect(x: 0, y: 0, width: leftSize.width, height: h))
right.draw(in: NSRect(x: leftSize.width + gap, y: 0, width: rightSize.width, height: h))
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) at \(Int(w))x\(Int(h))")
