import Foundation

/// Invisible markers, per PROTOCOL.md section 5: U+2060, base-240 digits as variation selectors
/// U+E0100 + digit, U+2060.
public enum Markers {
    static let joiner: Unicode.Scalar = "\u{2060}"
    static let firstSelector: UInt32 = 0xE0100

    public static func encode(_ id: Int) -> String {
        precondition(id >= 0)
        var digits: [UInt32] = []
        var v = id
        repeat {
            digits.append(UInt32(v % 240))
            v /= 240
        } while v > 0
        var s = String.UnicodeScalarView()
        s.append(joiner)
        for d in digits.reversed() { s.append(Unicode.Scalar(firstSelector + d)!) }
        s.append(joiner)
        return String(s)
    }

    /// The text without markers, and the marker numbers found in it, in order.
    public static func decode(_ text: String) -> (text: String, ids: [Int]) {
        guard text.unicodeScalars.contains(joiner) else { return (text, []) }
        var out = String.UnicodeScalarView()
        var ids: [Int] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == joiner {
                var j = i + 1
                var value = 0
                var count = 0
                while j < scalars.count, isSelector(scalars[j]) {
                    value = value * 240 + Int(scalars[j].value - firstSelector)
                    count += 1
                    j += 1
                }
                if count > 0, j < scalars.count, scalars[j] == joiner {
                    ids.append(value)
                    i = j + 1
                    continue
                }
            }
            out.append(scalars[i])
            i += 1
        }
        return (String(out), ids)
    }

    public static func strip(_ text: String) -> String { decode(text).text }

    static func isSelector(_ s: Unicode.Scalar) -> Bool {
        s.value >= firstSelector && s.value <= firstSelector + 239
    }
}
