import Foundation
import EventKit

// MARK: - Data Models

/// Represents an attendee from a calendar event
struct EventKitAttendee {
    let email: String
    let name: String?
    let isOrganizer: Bool
}

/// Represents a calendar event with meeting details
struct EventKitMeetingInfo {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let attendees: [EventKitAttendee]
    let calendarName: String
}

// MARK: - Protocol for Dependency Injection

/// Protocol for EventKit calendar reading - allows mocking in tests
protocol EventKitCalendarReaderProtocol {
    func requestAccess() async -> Bool
    func findMeeting(overlapping start: Date, end: Date) -> EventKitMeetingInfo?
}

// MARK: - EventKit Calendar Reader

/// Reads calendar events from Apple Calendar using EventKit
class EventKitCalendarReader: EventKitCalendarReaderProtocol {
    private let logger = DualLogger(category: "EventKitCalendarReader")
    private let eventStore: EKEventStore
    private let targetCalendarNames: [String]
    private let debugLogging: Bool
    
    /// Initialize with target calendar names
    /// - Parameters:
    ///   - targetCalendarNames: Names of calendars to search (default: ["Calendar"])
    ///   - debugLogging: Enable verbose logging
    init(targetCalendarNames: [String] = ["Calendar"], debugLogging: Bool = false) {
        self.eventStore = EKEventStore()
        self.targetCalendarNames = targetCalendarNames
        self.debugLogging = debugLogging
    }
    
    /// Request full access to calendar events
    /// - Returns: true if access was granted
    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                // Fallback for macOS 13 - use deprecated API
                granted = await withCheckedContinuation { continuation in
                    eventStore.requestAccess(to: .event) { success, error in
                        if let error = error {
                            self.logger.error("Calendar access error: \(error.localizedDescription)")
                        }
                        continuation.resume(returning: success)
                    }
                }
            }
            
            if granted {
                logger.info("✓ Calendar access granted")
            } else {
                logger.warning("Calendar access denied by user")
            }
            return granted
        } catch {
            logger.error("Failed to request calendar access: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Find a calendar event that overlaps with the given time window
    /// - Parameters:
    ///   - start: Recording start time
    ///   - end: Recording end time
    /// - Returns: Meeting info if found, nil otherwise
    func findMeeting(overlapping start: Date, end: Date) -> EventKitMeetingInfo? {
        // Get all calendars for events
        let allCalendars = eventStore.calendars(for: .event)
        
        if debugLogging {
            logger.debug("Available calendars: \(allCalendars.map { $0.title }.joined(separator: ", "))")
        }
        
        // Filter to target calendars
        let targetCals = allCalendars.filter { calendar in
            targetCalendarNames.contains(calendar.title)
        }
        
        if targetCals.isEmpty {
            logger.warning("No matching calendars found for: \(targetCalendarNames.joined(separator: ", "))")
            logger.info("Available calendars: \(allCalendars.map { $0.title }.joined(separator: ", "))")
            return nil
        }
        
        if debugLogging {
            logger.debug("Searching in calendars: \(targetCals.map { $0.title }.joined(separator: ", "))")
        }
        
        // Add buffer time to account for recording start/end delays
        let bufferMinutes: TimeInterval = 5 * 60  // 5 minutes
        let searchStart = start.addingTimeInterval(-bufferMinutes)
        let searchEnd = end.addingTimeInterval(bufferMinutes)
        
        // Create predicate for date range
        let predicate = eventStore.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: targetCals
        )
        
        // Fetch events
        let events = eventStore.events(matching: predicate)
        
        if debugLogging {
            logger.debug("Found \(events.count) events in time range")
            for event in events {
                logger.debug("  - \(event.title ?? "NO TITLE") (\(formatTime(event.startDate)) - \(formatTime(event.endDate)))")
            }
        }
        
        // Find the best matching event (overlaps with recording time)
        // Prefer events with more attendees (more likely to be meetings vs personal events)
        let matchingEvents = events.filter { event in
            eventOverlaps(event: event, recordingStart: start, recordingEnd: end)
        }
        
        // Sort by attendee count (descending) to prefer actual meetings
        let sortedEvents = matchingEvents.sorted { event1, event2 in
            (event1.attendees?.count ?? 0) > (event2.attendees?.count ?? 0)
        }
        
        guard let bestMatch = sortedEvents.first else {
            logger.info("No calendar event found overlapping recording window (\(formatTime(start)) - \(formatTime(end)))")
            return nil
        }
        
        logger.info("✓ Found matching calendar event: \(bestMatch.title ?? "NO TITLE")")
        
        return convertToMeetingInfo(event: bestMatch)
    }
    
    // MARK: - Private Helpers
    
    /// Check if an event overlaps with the recording time window
    private func eventOverlaps(event: EKEvent, recordingStart: Date, recordingEnd: Date) -> Bool {
        // Two intervals overlap if: start1 < end2 AND start2 < end1
        return event.startDate < recordingEnd && recordingStart < event.endDate
    }
    
    /// Convert EKEvent to our EventKitMeetingInfo struct
    private func convertToMeetingInfo(event: EKEvent) -> EventKitMeetingInfo {
        let attendees = extractAttendees(from: event)
        
        if debugLogging {
            logger.debug("Extracted \(attendees.count) attendees from event")
            for attendee in attendees {
                logger.debug("  - \(attendee.name ?? "NO NAME") <\(attendee.email)>\(attendee.isOrganizer ? " (organizer)" : "")")
            }
        }
        
        return EventKitMeetingInfo(
            title: event.title ?? "Untitled Meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            attendees: attendees,
            calendarName: event.calendar.title
        )
    }
    
    /// Extract attendees from an EKEvent
    private func extractAttendees(from event: EKEvent) -> [EventKitAttendee] {
        guard let ekAttendees = event.attendees else {
            return []
        }
        
        return ekAttendees.compactMap { attendee -> EventKitAttendee? in
            // Extract email from URL (format: mailto:email@example.com)
            let urlString = attendee.url.absoluteString
            let email: String
            if urlString.hasPrefix("mailto:") {
                email = String(urlString.dropFirst(7))
            } else {
                email = urlString
            }
            
            // Skip empty emails
            guard !email.isEmpty else { return nil }
            
            return EventKitAttendee(
                email: email,
                name: attendee.name,
                isOrganizer: attendee.isCurrentUser  // Note: isCurrentUser indicates the organizer
            )
        }
    }
    
    /// Format a date for logging (HH:mm:ss)
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
