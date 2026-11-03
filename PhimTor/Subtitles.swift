import Foundation
import Compression

struct Cue {
    var start: Double   // giây
    var end: Double
    var text: String
}

/// Tải + đọc phụ đề ngoài (SRT, VTT, ASS) — tự vẽ nên chạy chắc chắn trên iPhone
enum SubtitleLoader {
    static func load(_ urlStr: String) async throws -> [Cue] {
        guard let u = URL(string: urlStr) else { return [] }
        var r = URLRequest(url: u)
        r.timeoutInterval = 60
        let (raw, _) = try await URLSession.shared.data(for: r)
        var data = raw
        if data.count > 2, data[0] == 0x1f, data[1] == 0x8b, let g = gunzip(data) { data = g }
        let text = decode(data)
        if text.range(of: "[Script Info]", options: .caseInsensitive) != nil || text.contains("Dialogue:") {
            return parseAss(text)
        }
        return parseSrt(text)
    }

    static func decode(_ d: Data) -> String {
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: d.dropFirst(3), as: UTF8.self) }
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d, encoding: .utf16LittleEndian) ?? "" }
        if d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16BigEndian) ?? "" }
        if let s = String(data: d, encoding: .utf8) { return s }
        let viet = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0508)) // Windows-1258
        if let s = String(data: d, encoding: viet) { return s.precomposedStringWithCanonicalMapping }
        return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    static func time(_ s: Substring) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = t.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var sec = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; sec = sec * 60 + v }
        return sec
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseSrt(_ text: String) -> [Cue] {
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in norm.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let tp = lines[ti].components(separatedBy: "-->")
            guard tp.count == 2, let a = time(Substring(tp[0])), let b = time(Substring(tp[1])) else { continue }
            let body = clean(lines[(ti + 1)...].joined(separator: "\n"))
            if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseAss(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        var fmt: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("format:"), line.lowercased().contains("text"), line.lowercased().contains("start") {
                fmt = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:") {
                let parts = line.dropFirst(9).split(separator: ",", maxSplits: fmt.count - 1, omittingEmptySubsequences: false)
                guard parts.count == fmt.count,
                      let si = fmt.firstIndex(of: "start"), let ei = fmt.firstIndex(of: "end"),
                      let a = time(parts[si]), let b = time(parts[ei]) else { continue }
                let t = clean(String(parts[fmt.count - 1]).replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " "))
                if !t.isEmpty { cues.append(Cue(start: a, end: b, text: t)) }
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Tìm câu đang hiện ở thời điểm t (tìm nhị phân)
    static func text(at t: Double, in cues: [Cue]) -> String {
        var lo = 0, hi = cues.count - 1, idx = -1
        while lo <= hi {
            let m = (lo + hi) / 2
            if cues[m].start <= t { idx = m; lo = m + 1 } else { hi = m - 1 }
        }
        guard idx >= 0 else { return "" }
        var out: [String] = []
        var i = idx
        while i >= 0 && i > idx - 4 {
            if cues[i].start <= t && t <= cues[i].end { out.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return out.joined(separator: "\n")
    }

    static func gunzip(_ data: Data) -> Data? {
        // bỏ header gzip 10 byte (+ tên file nếu có), giải nén deflate thô
        guard data.count > 18 else { return nil }
        var start = 10
        let flags = data[3]
        if flags & 0x04 != 0 { start += 2 + Int(data[10]) + Int(data[11]) << 8 }
        if flags & 0x08 != 0 { while start < data.count && data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x10 != 0 { while start < data.count && data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x02 != 0 { start += 2 }
        let src = data.subdata(in: start..<(data.count - 8))
        let cap = max(src.count * 12, 1 << 20)
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? dst.prefix(n) : nil
    }
}
