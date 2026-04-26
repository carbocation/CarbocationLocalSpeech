import Foundation

public enum WhisperRuntimeModelProbe {
    public static func probeModelPath(for modelDirectory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first { $0.pathExtension.lowercased() == "bin" }
    }

    public static func probeModelPath(atPath path: String) -> String? {
        probeModelPath(for: URL(fileURLWithPath: path))?.path
    }
}
