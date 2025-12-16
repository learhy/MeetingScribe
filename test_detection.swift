#!/usr/bin/env swift
import Foundation
import Quartz

// Get windows on screen only
func getWindowsOnScreenOnly() -> [[String: Any]]? {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }
    
    // Filter for normal windows (layer 0)
    return windowList.filter { window in
        guard let layer = window[kCGWindowLayer as String] as? Int else { return false }
        return layer == 0
    }
}

print("Testing call detection...")
print()

if let windows = getWindowsOnScreenOnly() {
    print("Total windows at layer 0: \(windows.count)")
    print()
    
    // Count Teams windows
    let teamsWindows = windows.filter { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
        return owner.lowercased().contains("teams")
    }
    
    print("Teams windows at layer 0: \(teamsWindows.count)")
    print()
    
    if !teamsWindows.isEmpty {
        print("Teams window details:")
        for (i, window) in teamsWindows.enumerated() {
            let title = window[kCGWindowName as String] as? String ?? ""
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
            print("  [\(i)] owner=\(owner), title=\(title), pid=\(pid)")
        }
    }
} else {
    print("Failed to get windows")
}
