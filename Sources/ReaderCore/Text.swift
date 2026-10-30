import Foundation

public let maxTextScalars = 4000

/// Pull the message text out of an `attributedBody` typedstream blob.
///
/// New macOS versions often leave `message.text` NULL and store the text only
/// here. The blob is an NSArchiver typedstream of an NSAttributedString: the
/// first `NSString` class name is followed by a 5-byte header and a
/// length-prefixed UTF-8 string. Typedstream integers below 0x80 are one byte;
/// 0x81 introduces a 2-byte and 0x82 a 4-byte little-endian value (checked
/// against NSArchiver output on macOS 27).
///
/// Adapted from mac_messages_mcp (MIT, Copyright (c) 2023 Carter Lasalle).
public func decodeAttributedBody(_ blob: [UInt8]?) -> String? {
    guard let blob, !blob.isEmpty else { return nil }
    let marker = Array("NSString".utf8)
    guard let idx = firstIndex(of: marker, in: blob) else { return nil }
    var pos = idx + marker.count + 5
    guard pos < blob.count else { return nil }
    let lead = blob[pos]
    pos += 1
    let length: Int
    if lead < 0x80 {
        length = Int(lead)
    } else if lead == 0x81 || lead == 0x82 {
        let width = lead == 0x81 ? 2 : 4
        guard pos + width <= blob.count else { return nil }
        length = (0..<width).reduce(0) { $0 | Int(blob[pos + $1]) << (8 * $1) }
        pos += width
    } else {
        return nil
    }
    guard pos + length <= blob.count else { return nil }
    return String(decoding: blob[pos..<(pos + length)], as: UTF8.self)
}

private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
        if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
    }
    return nil
}

/// Normalize a phone number or email so differently formatted handles compare equal.
///
/// Phone numbers become country code + national number. A number written with
/// a leading + keeps its country code as given; without one, 10 digits (or 11
/// starting with 1) are taken as US/NANP numbers. Anything else is compared as
/// its bare digits, so numbers are never merged across countries.
public func handleKey(_ raw: String) -> String {
    let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if handle.contains("@") { return handle.lowercased() }
    let digits = String(handle.filter { $0.isASCII && $0.isNumber })
    if !handle.hasPrefix("+") && digits.count == 10 { return "1" + digits }
    return digits
}

private let phoneCharacters = Set("0123456789 \t().-")

/// Phone numbers and SMS short codes: phone punctuation with at least 3 digits.
public func isPhone(_ value: String) -> Bool {
    let body = value.hasPrefix("+") ? value.dropFirst() : Substring(value)
    guard !body.isEmpty, body.allSatisfy(phoneCharacters.contains) else { return false }
    return body.filter(\.isASCII).filter(\.isNumber).count >= 3
}

/// Case-insensitive containment with full Unicode case folding ("ß" matches "SS").
public func containsFolded(_ text: String, _ needle: String) -> Bool {
    text.range(of: needle, options: [.caseInsensitive]) != nil
}

func cleanText(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return "" }
    // U+FFFC marks where an attachment sits inline; U+FFFD-only bodies are undecodable.
    let cleaned = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.isEmpty && cleaned.unicodeScalars.allSatisfy({ $0 == "\u{FFFD}" }) { return "" }
    return cleaned
}

func capText(_ text: String) -> (String, Bool) {
    guard text.unicodeScalars.count > maxTextScalars else { return (text, false) }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.prefix(maxTextScalars))
    return (String(scalars), true)
}

public let appleEpoch = Date(timeIntervalSince1970: 978_307_200)

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f
}()

func appleTimeToISO(_ value: Int64?) -> String? {
    guard let value, value != 0 else { return nil }
    // Since macOS 10.13 dates are nanoseconds since 2001; older rows used seconds.
    let seconds = abs(value) > 100_000_000_000 ? Double(value) / 1e9 : Double(value)
    return isoFormatter.string(from: appleEpoch.addingTimeInterval(seconds))
}

func appleNanosSince(seconds ago: Double) -> Int64 {
    Int64((Date().timeIntervalSince(appleEpoch) - ago) * 1e9)
}
