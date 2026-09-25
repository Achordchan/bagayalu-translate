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

    // 截图翻译逐段判断源语言时，要确认短文本和整页语言是同一种书写系统，
    // 不能把认不出的书写系统一概当成相同（阿拉伯文页面上的希腊文不是阿拉伯文）。
    private(set) var containsArabic = false
    private(set) var containsHebrew = false
    private(set) var containsGreek = false
    private(set) var containsThai = false
    private(set) var containsDevanagari = false
    private(set) var containsBengali = false
    private(set) var containsTamil = false
    /// 有字母不属于上面任何一种书写系统（组合附加符号不算字母）。
    private(set) var containsUnclassifiedLetters = false

    init(in text: String) {
        for scalar in text.unicodeScalars {
            containsLetters = containsLetters || CharacterSet.letters.contains(scalar)

            let han = Self.isHan(scalar)
            let kana = Self.isKana(scalar)
            let hangul = Self.isHangul(scalar)
            let bopomofo = Self.isBopomofo(scalar)
            let cyrillic = Self.isCyrillic(scalar)
            let latin = Self.isLatin(scalar)
            let arabic = Self.isArabic(scalar)
            let hebrew = Self.isHebrew(scalar)
            let greek = Self.isGreek(scalar)
            let thai = Self.isThai(scalar)
            let devanagari = Self.isDevanagari(scalar)
            let bengali = Self.isBengali(scalar)
            let tamil = Self.isTamil(scalar)

            containsHan = containsHan || han
            containsKana = containsKana || kana
            containsHangul = containsHangul || hangul
            containsBopomofo = containsBopomofo || bopomofo
            containsCyrillic = containsCyrillic || cyrillic
            containsLatin = containsLatin || latin
            containsArabic = containsArabic || arabic
            containsHebrew = containsHebrew || hebrew
            containsGreek = containsGreek || greek
            containsThai = containsThai || thai
            containsDevanagari = containsDevanagari || devanagari
            containsBengali = containsBengali || bengali
            containsTamil = containsTamil || tamil

            // CJK 符号区里也有算作字母的（「々」「〇」），跟着汉字走，不算别的书写系统。
            let cjkSymbol = (0x3000...0x303F).contains(scalar.value)
            let classified = han || kana || hangul || bopomofo || cyrillic || latin
                || arabic || hebrew || greek || thai || devanagari || bengali || tamil || cjkSymbol
            if !classified, Self.isLetter(scalar) {
                containsUnclassifiedLetters = true
            }
        }
    }

    private static func isLetter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
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

    private static func isArabic(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF,
             0x0750...0x077F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isHebrew(_ scalar: UnicodeScalar) -> Bool {
        (0x0590...0x05FF).contains(scalar.value) || (0xFB1D...0xFB4F).contains(scalar.value)
    }

    private static func isGreek(_ scalar: UnicodeScalar) -> Bool {
        (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
    }

    private static func isThai(_ scalar: UnicodeScalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    private static func isDevanagari(_ scalar: UnicodeScalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value) || (0xA8E0...0xA8FF).contains(scalar.value)
    }

    private static func isBengali(_ scalar: UnicodeScalar) -> Bool {
        (0x0980...0x09FF).contains(scalar.value)
    }

    private static func isTamil(_ scalar: UnicodeScalar) -> Bool {
        (0x0B80...0x0BFF).contains(scalar.value)
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
