import Foundation

enum PluginError: Error {
    case saveFailed(String)
    case configurationError(String)
}

struct PluginResult {
    let noteId: String?
    let success: Bool
    let message: String
}

protocol NotesPlugin {
    var name: String { get }
    func save(note: String, title: String) async throws -> PluginResult
    func configure(settings: [String: Any]) -> Bool
    func healthCheck() async -> Bool
}
