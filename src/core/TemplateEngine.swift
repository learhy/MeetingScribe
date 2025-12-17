import Foundation

struct NoteData {
    let date: String
    let time: String
    let duration: String
    let title: String
    let summary: String
    let notes: String
    let transcript: String
    let audioFile: String
}

class TemplateEngine {
    private let logger = DualLogger(category: "TemplateEngine")
    private let config: ConfigManager
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    func render(noteData: NoteData) throws -> String {
        let template = try loadTemplate()
        return substituteVariables(template: template, data: noteData)
    }
    
    private func loadTemplate() throws -> String {
        let templatePath = config.expandPath(config.config.notes.templateFile)
        
        guard FileManager.default.fileExists(atPath: templatePath.path) else {
            logger.warning("Template file not found, using default")
            return defaultTemplate
        }
        
        do {
            return try String(contentsOf: templatePath, encoding: .utf8)
        } catch {
            logger.warning("Failed to load template, using default")
            return defaultTemplate
        }
    }
    
    private func substituteVariables(template: String, data: NoteData) -> String {
        var result = template
        
        result = result.replacingOccurrences(of: "{date}", with: data.date)
        result = result.replacingOccurrences(of: "{time}", with: data.time)
        result = result.replacingOccurrences(of: "{duration}", with: data.duration)
        result = result.replacingOccurrences(of: "{title}", with: data.title)
        result = result.replacingOccurrences(of: "{summary}", with: data.summary)
        result = result.replacingOccurrences(of: "{notes}", with: data.notes)
        result = result.replacingOccurrences(of: "{transcript}", with: data.transcript)
        result = result.replacingOccurrences(of: "{audio_file}", with: data.audioFile)
        
        return result
    }
    
    private var defaultTemplate: String {
        """
        # {title}
        
        ---
        
        **Date:** {date}
        **Time:** {time}
        **Duration:** {duration}
        
        ## Summary
        {summary}
        
        ## Notes
        {notes}
        
        ## Full Transcript
        {transcript}
        
        ---
        *Generated automatically by MeetingScribe*
        *Audio: {audio_file}*
        """
    }
}
