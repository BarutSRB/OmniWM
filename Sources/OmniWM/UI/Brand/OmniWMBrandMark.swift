// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

enum OmniWMBrandMark {
    static func statusItemImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext, let glyph = glyphPath("O") else {
                return true
            }
            context.addPath(fit(glyph, into: rect.insetBy(dx: pointSize * 0.08, dy: pointSize * 0.06)))
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func omniWordmarkPath(in rect: CGRect) -> CGPath {
        guard let glyph = glyphPath("Omni") else { return CGMutablePath() }
        return fit(glyph, into: rect)
    }

    static var omniWordmarkAspect: CGFloat {
        guard let glyph = glyphPath("Omni") else { return 2.6 }
        let box = glyph.boundingBoxOfPath
        return box.height > 0 ? box.width / box.height : 2.6
    }

    private static func font() -> CTFont? {
        let candidates = [("LoftyGoals", "otf"), ("LoftyGoals", "ttf")]
        for (name, ext) in candidates {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first
            else { continue }
            return CTFontCreateWithFontDescriptor(descriptor, 100, nil)
        }
        return nil
    }

    private static func glyphPath(_ text: String) -> CGPath? {
        guard let font = font() else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        let combined = CGMutablePath()
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0 ..< count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                combined.addPath(
                    glyph,
                    transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                )
            }
        }
        return combined.isEmpty ? nil : combined
    }

    private static func fit(_ path: CGPath, into rect: CGRect) -> CGPath {
        let box = path.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return path }
        let scale = min(rect.width / box.width, rect.height / box.height)
        var transform = CGAffineTransform(translationX: rect.midX - box.midX * scale, y: rect.midY - box.midY * scale)
            .scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}
