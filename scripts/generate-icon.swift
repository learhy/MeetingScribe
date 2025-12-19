#!/usr/bin/env swift

import AppKit

// Generate app icon from SF Symbol
func generateIcon() {
    let sizes: [(Int, String)] = [
        (16, "icon_16x16"),
        (32, "icon_16x16@2x"),
        (32, "icon_32x32"),
        (64, "icon_32x32@2x"),
        (128, "icon_128x128"),
        (256, "icon_128x128@2x"),
        (256, "icon_256x256"),
        (512, "icon_256x256@2x"),
        (512, "icon_512x512"),
        (1024, "icon_512x512@2x")
    ]
    
    let iconsetPath = "resources/AppIcon.iconset"
    
    for (size, filename) in sizes {
        // Create a square image
        let imageSize = NSSize(width: size, height: size)
        let image = NSImage(size: imageSize)
        
        image.lockFocus()
        
        // Background gradient (light blue to white)
        let gradient = NSGradient(starting: NSColor(red: 0.9, green: 0.95, blue: 1.0, alpha: 1.0),
                                 ending: NSColor.white)
        gradient?.draw(in: NSRect(origin: .zero, size: imageSize), angle: 90)
        
        // Draw pen and paper icon using SF Symbol
        if let symbolImage = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil) {
            let symbolSize = CGFloat(size) * 0.6
            let symbolRect = NSRect(x: (CGFloat(size) - symbolSize) / 2,
                                   y: (CGFloat(size) - symbolSize) / 2,
                                   width: symbolSize,
                                   height: symbolSize)
            
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
            let configuredSymbol = symbolImage.withSymbolConfiguration(config)
            
            // Draw with color
            NSColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1.0).set()
            configuredSymbol?.draw(in: symbolRect)
        }
        
        image.unlockFocus()
        
        // Save as PNG
        if let tiffData = image.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            let path = "\(iconsetPath)/\(filename).png"
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Generated: \(path)")
        }
    }
    
    print("✅ Icon set generated at \(iconsetPath)")
    print("Run: iconutil -c icns resources/AppIcon.iconset -o resources/AppIcon.icns")
}

generateIcon()
