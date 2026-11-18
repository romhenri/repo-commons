import AppKit
import SwiftUI

// Brand identity: git orange #F05032. Single source for the icon and the UI.
extension NSColor { static let brand = NSColor(red: 0xF0 / 255, green: 0x50 / 255, blue: 0x32 / 255, alpha: 1) }
extension Color { static let brand = Color(nsColor: .brand) }

// App icon: orange honeycomb on white. Drawn in code so `swift run` gets it too;
// bundle.sh renders it to AppIcon.icns via `RepoCommons --render-icon out.png`.
private let size: CGFloat = 1024

@MainActor let appIcon = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824pt body inset 100pt, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Seven flat-top hexagons: one centre cell and six around it.
    let r: CGFloat = 112, gap: CGFloat = 14
    let centre = CGPoint(x: size / 2, y: size / 2)
    var cells = [centre]
    for k in 0..<6 {
        let a = CGFloat(k) * .pi / 3 + .pi / 6
        cells.append(CGPoint(x: centre.x + sqrt(3) * r * cos(a), y: centre.y + sqrt(3) * r * sin(a)))
    }
    NSColor.brand.setFill()
    for c in cells {
        let hex = NSBezierPath()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            let p = CGPoint(x: c.x + (r - gap) * cos(a), y: c.y + (r - gap) * sin(a))
            k == 0 ? hex.move(to: p) : hex.line(to: p)
        }
        hex.close()
        hex.fill()
    }
    return true
}

@MainActor func renderIcon(to path: String) throws {
    let rep = NSBitmapImageRep(data: appIcon.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
