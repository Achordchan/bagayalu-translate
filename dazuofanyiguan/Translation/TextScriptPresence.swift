import Foundation

/// 一段文字里出现过哪些书写系统。
///
/// 原本是 `MiniTranslationDirectionResolver` 的私有类型，
/// `LanguageScriptFallback` 也要用同一套判断，抽出来共享，避免两处各写一份字符区间。
struct TextScriptPresence {
    private(set) var containsCyrillic = false
    private(set) var containsLatin = false

    private(set) var containsLetters = false
    private(set) var containsHan = false
    private(set) var containsKana = false
    private(set) var containsHangul = false
    private(set) var containsBopomofo = false

    init(in text: String) {
        for scalar in text.unicodeScalars {
            containsLetters = containsLetters || CharacterSet.letters.contains(scalar)
            containsHan = containsHan || Self.isHan(scalar)
            containsKana = containsKana || Self.isKana(scalar)
            containsHangul = containsHangul || Self.isHangul(scalar)
            containsBopomofo = containsBopomofo || Self.isBopomofo(scalar)
            containsCyrillic = containsCyrillic || Self.isCyrillic(scalar)
            containsLatin = containsLatin || Self.isLatin(scalar)
        }
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,
             0x31F0...0x31FF,
             0xFF65...0xFF9F:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xA960...0xA97F,
             0xAC00...0xD7AF,
             0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }

    private static func isBopomofo(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3100...0x312F,
             0x31A0...0x31BF:
            return true
        default:
            return false
        }
    }

    private static func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0400...0x04FF,
             0x0500...0x052F,
             0x2DE0...0x2DFF,
             0xA640...0xA69F:
            return true
        default:
            return false
        }
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A,
             0x0061...0x007A,
             0x00C0...0x024F,
             0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }
}
