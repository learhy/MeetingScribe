import AppKit

class DetectionTab: BasePreferencesTab {
    override var tabName: String { "Detection" }
    
    private var pollIntervalField: NSTextField!
    private var confidenceSlider: NSSlider!
    private var confidenceField: NSTextField!
    private var debounceField: NSTextField!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        var yPos = 380
        
        // Title
        let titleLabel = NSTextField(labelWithString: "Meeting Detection Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        addSubview(titleLabel)
        yPos -= 40
        
        // Poll Interval
        let pollLabel = NSTextField(labelWithString: "Poll Interval (seconds):")
        pollLabel.frame = NSRect(x: 20, y: yPos, width: 180, height: 20)
        pollLabel.alignment = .right
        addSubview(pollLabel)
        
        pollIntervalField = NSTextField(frame: NSRect(x: 210, y: yPos, width: 60, height: 22))
        pollIntervalField.placeholderString = "2"
        pollIntervalField.target = self
        pollIntervalField.action = #selector(textFieldChanged)
        addSubview(pollIntervalField)
        
        let pollHelp = NSTextField(labelWithString: "How often to check for meetings")
        pollHelp.font = NSFont.systemFont(ofSize: 10)
        pollHelp.textColor = .secondaryLabelColor
        pollHelp.frame = NSRect(x: 280, y: yPos + 2, width: 290, height: 20)
        addSubview(pollHelp)
        yPos -= 40
        
        // Confidence Threshold
        let confidenceLabel = NSTextField(labelWithString: "Confidence Threshold (%):")
        confidenceLabel.frame = NSRect(x: 20, y: yPos, width: 180, height: 20)
        confidenceLabel.alignment = .right
        addSubview(confidenceLabel)
        
        confidenceSlider = NSSlider(frame: NSRect(x: 210, y: yPos, width: 280, height: 22))
        confidenceSlider.minValue = 0
        confidenceSlider.maxValue = 100
        confidenceSlider.integerValue = 85
        confidenceSlider.target = self
        confidenceSlider.action = #selector(sliderChanged)
        addSubview(confidenceSlider)
        
        confidenceField = NSTextField(frame: NSRect(x: 500, y: yPos, width: 50, height: 22))
        confidenceField.placeholderString = "85"
        confidenceField.target = self
        confidenceField.action = #selector(confidenceFieldChanged)
        addSubview(confidenceField)
        yPos -= 25
        
        let confidenceHelp = NSTextField(labelWithString: "Minimum confidence level to detect a meeting")
        confidenceHelp.font = NSFont.systemFont(ofSize: 10)
        confidenceHelp.textColor = .secondaryLabelColor
        confidenceHelp.frame = NSRect(x: 210, y: yPos, width: 340, height: 20)
        addSubview(confidenceHelp)
        yPos -= 40
        
        // Debounce Checks
        let debounceLabel = NSTextField(labelWithString: "Debounce Checks:")
        debounceLabel.frame = NSRect(x: 20, y: yPos, width: 180, height: 20)
        debounceLabel.alignment = .right
        addSubview(debounceLabel)
        
        debounceField = NSTextField(frame: NSRect(x: 210, y: yPos, width: 60, height: 22))
        debounceField.placeholderString = "2"
        debounceField.target = self
        debounceField.action = #selector(textFieldChanged)
        addSubview(debounceField)
        
        let debounceHelp = NSTextField(labelWithString: "Number of consistent checks required")
        debounceHelp.font = NSFont.systemFont(ofSize: 10)
        debounceHelp.textColor = .secondaryLabelColor
        debounceHelp.frame = NSRect(x: 280, y: yPos + 2, width: 290, height: 20)
        addSubview(debounceHelp)
    }
    
    @objc private func textFieldChanged() {
        markDirty()
    }
    
    @objc private func sliderChanged() {
        // Sync slider to field
        confidenceField.integerValue = confidenceSlider.integerValue
        markDirty()
    }
    
    @objc private func confidenceFieldChanged() {
        // Sync field to slider
        let value = confidenceField.integerValue
        if value >= 0 && value <= 100 {
            confidenceSlider.integerValue = value
        }
        markDirty()
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        pollIntervalField.stringValue = String(format: "%.1f", config.detection.pollInterval)
        confidenceSlider.integerValue = config.detection.confidenceThreshold
        confidenceField.integerValue = config.detection.confidenceThreshold
        debounceField.integerValue = config.detection.debounceChecks
        
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        
        // Poll interval must be >= 1
        if let pollValue = Double(pollIntervalField.stringValue), pollValue < 1.0 {
            errors.append(ValidationError(field: "Poll Interval", message: "Poll Interval must be at least 1 second"))
        } else if Double(pollIntervalField.stringValue) == nil {
            errors.append(ValidationError(field: "Poll Interval", message: "Poll Interval must be a number"))
        }
        
        // Confidence threshold auto-clamped by slider (0-100)
        
        // Debounce checks must be >= 1
        if let debounceValue = Int(debounceField.stringValue), debounceValue < 1 {
            errors.append(ValidationError(field: "Debounce Checks", message: "Debounce Checks must be at least 1"))
        } else if Int(debounceField.stringValue) == nil {
            errors.append(ValidationError(field: "Debounce Checks", message: "Debounce Checks must be a number"))
        }
        
        return errors
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        config.detection.pollInterval = Double(pollIntervalField.stringValue) ?? 2.0
        config.detection.confidenceThreshold = confidenceSlider.integerValue
        config.detection.debounceChecks = Int(debounceField.stringValue) ?? 2
    }
}
