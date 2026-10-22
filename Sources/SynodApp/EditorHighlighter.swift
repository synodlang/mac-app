import AppKit
import SynodCore

/// The standard palette (`std/theme`) as the editor uses it: the dark values are the brand
/// colors; the light values keep the same roles on a pale ground.
enum EditorPalette: CaseIterable {
    case paper, ink, quiet, accent, good, warning, critical

    func hex(dark: Bool) -> UInt32 {
        switch self {
        case .paper: return dark ? 0x151A2E : 0xFBF8F1
        case .ink: return dark ? 0xEDE9E1 : 0x1D2238
        case .quiet: return dark ? 0x8A90A8 : 0x6B7190
        case .accent: return dark ? 0xF4A340 : 0xB4640A
        case .good: return dark ? 0x5CC8B8 : 0x16806F
        case .warning: return dark ? 0xE8C35A : 0x92700F
        case .critical: return dark ? 0xE86F5A : 0xC23B25
        }
    }

    func color(dark: Bool) -> NSColor { Self.rgb(hex(dark: dark)) }

    /// A color that follows the appearance of the view that draws it. One object per palette
    /// entry, so attributes can be compared by identity.
    var color: NSColor { Self.colors[self]! }

    private static let colors: [EditorPalette: NSColor] = Dictionary(uniqueKeysWithValues: allCases.map { entry in
        (entry, NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return entry.color(dark: dark)
        })
    })

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// How a token role looks (`06-mac-app.md`): comment Quiet italic, language Accent, phrase Ink
/// semibold, name Ink, field Good, type Warning, value Critical. Lexical-only files carry only
/// the roles the lexer can tell, so they take the same table.
enum EditorHighlighter {
    struct Style: Equatable {
        var color: EditorPalette
        var semibold = false
        var italic = false
    }

    static func style(for role: SynodToken.Role) -> Style {
        switch role {
        case .comment: return Style(color: .quiet, italic: true)
        case .language: return Style(color: .accent)
        case .phrase: return Style(color: .ink, semibold: true)
        case .name, .unknown: return Style(color: .ink)
        case .field: return Style(color: .good)
        case .type: return Style(color: .warning)
        case .value: return Style(color: .critical)
        }
    }

    static var fontSize: CGFloat = 12.5

    static func font(semibold: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: fontSize, weight: semibold ? .semibold : .regular)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font(semibold: false), .foregroundColor: EditorPalette.ink.color]
    }

    static func attributes(for role: SynodToken.Role) -> [NSAttributedString.Key: Any] {
        let s = style(for: role)
        var a: [NSAttributedString.Key: Any] = [.font: font(semibold: s.semibold), .foregroundColor: s.color.color]
        if s.italic { a[.obliqueness] = 0.2 }
        return a
    }

    /// Attributes of a diagnostic span: an underline (a dotted one for a secondary label) and the
    /// message as a tooltip.
    static func attributes(for mark: EditorMark) -> [NSAttributedString.Key: Any] {
        switch mark.kind {
        case .error:
            return [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: EditorPalette.critical.color,
                    .toolTip: mark.tooltip]
        case .warning:
            return [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: EditorPalette.warning.color,
                    .toolTip: mark.tooltip]
        case .label:
            return [.underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
                    .underlineColor: EditorPalette.quiet.color, .toolTip: mark.tooltip]
        }
    }

    /// Resets `storage` to the base look and colors every token and mark. Tokens that do not fit
    /// the text are skipped. Returns how many tokens were colored.
    @discardableResult
    static func apply(tokens: [PositionedToken], marks: [EditorMark], to storage: NSTextStorage) -> Int {
        let length = storage.length
        var colored = 0
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: length))
        for t in tokens where t.range.location >= 0 && NSMaxRange(t.range) <= length && t.range.length > 0 {
            storage.addAttributes(attributes(for: t.role), range: t.range)
            colored += 1
        }
        for m in marks where m.range.location >= 0 && NSMaxRange(m.range) <= length && m.range.length > 0 {
            storage.addAttributes(attributes(for: m), range: m.range)
        }
        storage.endEditing()
        return colored
    }
}
