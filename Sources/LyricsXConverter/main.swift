import Foundation
import LyricsXCore
import LyricsXServices

@main
struct LyricsXConverter {
    static func main() async {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--directory"), arguments.indices.contains(flag + 1) else {
            fputs("Usage: LyricsXConverter --directory /path/to/LyricsX [--backup /path]\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let backup: URL
        if let backupFlag = arguments.firstIndex(of: "--backup"), arguments.indices.contains(backupFlag + 1) {
            backup = URL(fileURLWithPath: arguments[backupFlag + 1], isDirectory: true)
        } else {
            backup = directory.deletingLastPathComponent().appendingPathComponent("LyricsX-lrcx-backup-\(Self.timestamp())", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let inputs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension.lowercased() == "lrcx" }
            var converted = 0
            var failed: [(URL, String)] = []
            for input in inputs {
                do {
                    let document = try LyricsCodec.read(input)
                    let output = input.deletingPathExtension().appendingPathExtension("lrc")
                    let value = Self.standardLRC(document)
                    let parsed = try LyricsCodec.parse(value)
                    guard parsed.lines.count == document.lines.count || document.isInstrumental || !document.isSynced else {
                        throw ConversionError.verificationFailed
                    }
                    try FileManager.default.copyItem(at: input, to: backup.appendingPathComponent(input.lastPathComponent))
                    let temporary = output.appendingPathExtension("tmp")
                    try value.write(to: temporary, atomically: true, encoding: .utf8)
                    _ = try String(contentsOf: temporary, encoding: .utf8)
                    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                    try FileManager.default.moveItem(at: temporary, to: output)
                    try FileManager.default.removeItem(at: input)
                    converted += 1
                } catch {
                    failed.append((input, error.localizedDescription))
                }
            }
            print("directory=\(directory.path)")
            print("backup=\(backup.path)")
            print("found=\(inputs.count) converted=\(converted) failed=\(failed.count)")
            for (url, error) in failed { print("FAILED \(url.lastPathComponent): \(error)") }
            if !failed.isEmpty { exit(1) }
        } catch {
            fputs("Conversion failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func standardLRC(_ document: LyricsDocument) -> String {
        var lines: [String] = []
        if !document.title.isEmpty { lines.append("[ti:\(Self.clean(document.title))]") }
        if !document.artist.isEmpty { lines.append("[ar:\(Self.clean(document.artist))]") }
        if !document.album.isEmpty { lines.append("[al:\(Self.clean(document.album))]") }
        lines.append("[offset:\(document.offsetMilliseconds)]")
        if document.isInstrumental { lines.append("[00:00.000]") }
        else if document.isSynced {
            for line in document.lines {
                let stamp = "[\(String(format: "%02d:%06.3f", Int(line.time) / 60, line.time.truncatingRemainder(dividingBy: 60)))]"
                lines.append(stamp + line.text)
                if let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty, translation != line.text {
                    lines.append(stamp + "[tr]" + translation.replacingOccurrences(of: "\n", with: " "))
                }
            }
        } else if let plainText = document.plainText { lines.append(contentsOf: plainText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clean(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "]", with: "") }
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") }
    private enum ConversionError: LocalizedError { case verificationFailed; var errorDescription: String? { "converted LRC did not pass parser verification" } }
}
