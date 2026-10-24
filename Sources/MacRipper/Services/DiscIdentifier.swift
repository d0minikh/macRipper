import Foundation

/// Determines the disc type and a first guess of the title (ARM: identify.py).
enum DiscIdentifier {
    static func discType(mountPoint: String?, mediaKind: String) -> DiscType {
        guard let mp = mountPoint else { return mediaKind == "IOCDMedia" ? .audioCD : .unknown }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: (mp as NSString).appendingPathComponent(name))
        }
        if exists("BDMV") || exists("bdmv") { return .bluray }
        if exists("VIDEO_TS") || exists("video_ts") { return .dvd }
        if mediaKind == "IOCDMedia", exists(".TOC.plist") { return .audioCD }
        if mediaKind == "IOCDMedia",
           let files = try? fm.contentsOfDirectory(atPath: mp),
           !files.isEmpty, files.allSatisfy({ $0.hasPrefix(".") || $0.lowercased().hasSuffix(".aiff") }) {
            return .audioCD
        }
        return .data
    }

    static func volumeLabel(mountPoint: String) -> String {
        (mountPoint as NSString).lastPathComponent
    }

    /// Blu-rays often carry the real title in BDMV/META/DL/bdmt_eng.xml.
    static func blurayTitle(mountPoint: String) -> String? {
        let dir = (mountPoint as NSString).appendingPathComponent("BDMV/META/DL")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let candidates = files.filter { $0.hasPrefix("bdmt_") && $0.hasSuffix(".xml") }
            .sorted { a, b in a.contains("eng") && !b.contains("eng") }
        for file in candidates {
            guard let xml = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(file), encoding: .utf8),
                  let start = xml.range(of: "<di:name>"),
                  let end = xml.range(of: "</di:name>", range: start.upperBound..<xml.endIndex)
            else { continue }
            let name = String(xml[start.upperBound..<end.lowerBound])
                .replacingOccurrences(of: " - Blu-ray", with: "")
                .replacingOccurrences(of: "Blu-ray", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Turns labels like "THE_MATRIX_DISC_1_WS" into a search friendly "The Matrix".
    static func cleanLabel(_ label: String) -> String {
        var s = label.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let noise = [
            #"(?i)\b(disc|disk|dvd|cd|bd|d)\s*\d+\b"#, #"(?i)\bside\s*[ab]\b"#,
            #"(?i)\b(ws|fs|widescreen|fullscreen|16x9|4x3|pal|ntsc)\b"#,
            #"(?i)\b(se|special edition|collectors edition|extended|unrated|directors cut|ce)\b"#,
            #"(?i)\b(blu ?ray|bluray|uhd|4k|3d)\b"#, #"(?i)\bseason\s*\d+.*$"#, #"(?i)\bs\d{1,2}(d\d+)?\b"#,
        ]
        for pattern in noise {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s == s.uppercased() { s = s.capitalized }
        return s
    }

    /// Detects a season hint in the label, used to classify TV discs.
    static func looksLikeSeries(_ label: String) -> Bool {
        label.range(of: #"(?i)(season|staffel|\bs\d{1,2}(d\d+)?\b|\bseries\b)"#, options: .regularExpression) != nil
    }
}
