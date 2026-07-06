#!/usr/bin/env swift

import Foundation

print("Testing Process with ffmpeg...")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
process.arguments = [
    "-i", "/Users/dan.rohan/Documents/MeetingScribe/recordings/meeting_2025-12-15_15-06-51_mixed.wav",
    "-ar", "16000",
    "-ac", "1",
    "-c:a", "pcm_s16le",
    "-y",
    "/tmp/swift_test.wav"
]

// Test 1: With nullDevice
print("Test 1: With nullDevice")
process.standardInput = FileHandle.nullDevice
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice

let start = Date()
try! process.run()
print("Process started, waiting...")
process.waitUntilExit()
let elapsed = Date().timeIntervalSince(start)

print("Exit code: \(process.terminationStatus)")
print("Elapsed: \(elapsed)s")
print("Done!")
