import Foundation
import AppKit

class BearPlugin: NotesPlugin {
    let name = "Bear"
    private let logger = DualLogger(category: "BearPlugin")
    private let config: ConfigManager
    private var tags: [String] = []
    private var fallbackDirectory: URL?
    
    init(config: ConfigManager = .shared) {
        self.config = config
        self.tags = config.config.notes.bear.tags
        self.fallbackDirectory = config.expandPath(config.config.notes.bear.fallbackDirectory)
    }
    
    func save(note: String, title: String) async throws -> PluginResult {
        logger.info("Saving note to Bear: \(title)")
        
        // Try Bear first
        if await healthCheck() {
            do {
                try await saveToBear(note: note, title: title)
                logger.info("Note saved to Bear successfully")
                return PluginResult(noteId: nil, success: true, message: "Saved to Bear")
            } catch {
                logger.warning("Failed to save to Bear: \(error.localizedDescription)")
                logger.info("Falling back to local file")
            }
        }
        
        // Fallback to local file
        try saveToFile(note: note, title: title)
        return PluginResult(noteId: nil, success: true, message: "Saved to fallback directory")
    }
    
    private func saveToFile(note: String, title: String) throws {
        guard let fallbackDir = fallbackDirectory else {
            throw PluginError.configurationError("Fallback directory not configured")
        }
        
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        
        let sanitizedTitle = title.replacingOccurrences(of: "[^a-zA-Z0-9-_ ]", with: "", options: .regularExpression)
        let filename = "\(sanitizedTitle).md"
        let fileURL = fallbackDir.appendingPathComponent(filename)
        
        try note.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Note saved to file: \(fileURL.path)")
    }
    
    private func saveToBear(note: String, title: String) async throws {
        // Prepare Bear x-callback-url
        var components = URLComponents(string: "bear://x-callback-url/create")!
        
        let tagsString = tags.joined(separator: ",")
        
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "text", value: note),
            URLQueryItem(name: "tags", value: tagsString)
        ]
        
        guard let url = components.url else {
            throw PluginError.saveFailed("Failed to construct Bear URL")
        }
        
        // Open URL
        await NSWorkspace.shared.open(url)
        
        // Give Bear time to process
        try await Task.sleep(for: .seconds(1))
    }
    
    func configure(settings: [String: Any]) -> Bool {
        if let newTags = settings["tags"] as? [String] {
            tags = newTags
        }
        if let fallbackPath = settings["fallbackDirectory"] as? String {
            fallbackDirectory = URL(fileURLWithPath: (fallbackPath as NSString).expandingTildeInPath)
        }
        return true
    }
    
    func healthCheck() async -> Bool {
        // Check if Bear is installed
        let bearBundleId = "net.shinyfrog.bear"
        let bearURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bearBundleId)
        return bearURL != nil
    }
}
