import Foundation

/// Appends timestamped lines to Documents/trace.log in UI-test sandbox runs (kept across launches), so a hang on the
/// device can be read back with devicectl. Does nothing in normal use.
enum Trace {
    nonisolated static func log(_ line: String) {
        guard AssistantModel.sandboxed,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("trace.log")
        let text = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
