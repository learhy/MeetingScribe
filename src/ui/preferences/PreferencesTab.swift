import AppKit

/// Protocol that all preferences tab views must implement
protocol PreferencesTab: NSView {
    /// The display name for this tab
    var tabName: String { get }
    
    /// Load configuration values into UI controls
    func loadConfig(_ config: AppConfiguration)
    
    /// Validate current UI values and return any errors
    func validate() -> [ValidationError]
    
    /// Collect changes from UI into configuration object
    func collectChanges(into config: inout AppConfiguration)
    
    /// Check if any values have been modified
    var isDirty: Bool { get }
    
    /// Reset dirty state (called after successful save)
    func resetDirtyState()
}

/// Base class for preference tabs providing common functionality
class BasePreferencesTab: NSView, PreferencesTab {
    var tabName: String { "Base" }
    
    private var _isDirty = false
    var isDirty: Bool { _isDirty }
    
    func loadConfig(_ config: AppConfiguration) {
        // Override in subclass
    }
    
    func validate() -> [ValidationError] {
        // Override in subclass
        return []
    }
    
    func collectChanges(into config: inout AppConfiguration) {
        // Override in subclass
    }
    
    func resetDirtyState() {
        _isDirty = false
    }
    
    /// Mark as dirty when user changes a value
    func markDirty() {
        _isDirty = true
    }
}
