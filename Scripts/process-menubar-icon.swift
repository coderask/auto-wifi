#!/usr/bin/env swift
//
// Convert a blue-on-white source PNG into a black-on-transparent template image suitable
// for use as a macOS menubar icon. macOS template images must be solid black with alpha
// for anti-aliasing; the system tints them appropriately for light/dark mode at runtime.
//
// Usage:
//   swift Scripts/process-menubar-icon.swift INPUT.png OUTPUT.png
//
// Algorithm: for each pixel, treat blueness (B − R) as alpha and set the color to black.
// White pixels → fully transparent. Blue pixels → near-fully-opaque black. Anti-aliased
// edges get a graduated alpha for a clean look at all sizes.

import Foundation
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: process-menubar-icon.swift INPUT OUTPUT\n".data(using: .utf8)!)
    exit(2)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let nsImage = NSImage(contentsOf: inputURL),
      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("could not load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel

var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    FileHandle.standardError.write("CGContext failed\n".data(using: .utf8)!)
    exit(1)
}

context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

// Threshold scan: blue pixels have R ≪ B. Compute "non-redness" = 255 - R as a proxy for
// alpha. Boost slightly so pure blue ends up near-opaque, then clamp.
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * bytesPerPixel
        let r = pixels[i]
        // Anything with R≈255 is white background → fully transparent.
        // Anything with low R is icon ink → near-opaque black.
        // Multiplier 1.4 makes the pure-blue interior ~99% opaque while keeping
        // anti-aliased edges semi-transparent.
        let alpha = max(0, min(255, Int(Double(255 - Int(r)) * 1.4)))
        pixels[i]     = 0      // R
        pixels[i + 1] = 0      // G
        pixels[i + 2] = 0      // B
        pixels[i + 3] = UInt8(alpha)
    }
}

guard let outCGImage = context.makeImage(),
      let bitmapRep = NSBitmapImageRep(cgImage: outCGImage).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
    exit(1)
}

try bitmapRep.write(to: outputURL)
print("✓ wrote \(args[2])")
