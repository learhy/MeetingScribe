#!/bin/bash

# MeetingScribe Daemon Control Script
# Usage: meetingscribe-ctl {start|stop|restart|status|logs}

set -e

PLIST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.meetingscribe.daemon"
LOG_FILE="$HOME/Library/Logs/MeetingScribe/stderr.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: meetingscribe-ctl {start|stop|restart|status|logs|version}"
    echo ""
    echo "Commands:"
    echo "  start    - Start the MeetingScribe daemon"
    echo "  stop     - Stop the MeetingScribe daemon"
    echo "  restart  - Restart the MeetingScribe daemon"
    echo "  status   - Check if daemon is running"
    echo "  logs     - View daemon logs (tail -f)"
    echo "  version  - Show installed version"
    exit 1
}

check_installed() {
    if [ ! -f "$PLIST" ]; then
        echo -e "${RED}❌ MeetingScribe is not installed${NC}"
        echo ""
        echo "Installation options:"
        echo "  1. Launch MeetingScribe.app from /Applications (recommended)"
        echo "     The first-run installer will set everything up automatically."
        echo ""
        echo "  2. Or manually run from source:"
        echo "     cd /path/to/meeting-scribe && ./scripts/install.sh"
        echo ""
        
        # Check if app exists and suggest launching it
        if [ -d "/Applications/MeetingScribe.app" ]; then
            echo "App found at: /Applications/MeetingScribe.app"
            echo "Run: open /Applications/MeetingScribe.app"
        elif [ -d "$HOME/Applications/MeetingScribe.app" ]; then
            echo "App found at: $HOME/Applications/MeetingScribe.app"
            echo "Run: open '$HOME/Applications/MeetingScribe.app'"
        fi
        
        exit 1
    fi
}

daemon_status() {
    if launchctl list | grep -q "$LABEL"; then
        echo -e "${GREEN}✅ MeetingScribe daemon is running${NC}"
        launchctl list | grep "$LABEL"
        return 0
    else
        echo -e "${YELLOW}⚠️  MeetingScribe daemon is not running${NC}"
        return 1
    fi
}

daemon_start() {
    check_installed
    
    if launchctl list | grep -q "$LABEL"; then
        echo -e "${YELLOW}⚠️  Daemon is already running${NC}"
        return 0
    fi
    
    echo "Starting MeetingScribe daemon..."
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  Daemon already loaded, attempting to start...${NC}"
        launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true
    }
    
    sleep 1
    
    if daemon_status >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Daemon started successfully${NC}"
    else
        echo -e "${RED}❌ Failed to start daemon${NC}"
        exit 1
    fi
}

daemon_stop() {
    check_installed
    
    if ! launchctl list | grep -q "$LABEL"; then
        echo -e "${YELLOW}⚠️  Daemon is not running${NC}"
        return 0
    fi
    
    echo "Stopping MeetingScribe daemon..."
    launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  Attempting alternative stop method...${NC}"
        launchctl kill SIGTERM "$DOMAIN/$LABEL" 2>/dev/null || true
        sleep 1
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    }
    
    sleep 1
    
    if ! launchctl list | grep -q "$LABEL"; then
        echo -e "${GREEN}✅ Daemon stopped successfully${NC}"
    else
        echo -e "${RED}❌ Failed to stop daemon completely${NC}"
        exit 1
    fi
}

daemon_restart() {
    echo "Restarting MeetingScribe daemon..."
    daemon_stop
    sleep 2
    daemon_start
}

daemon_logs() {
    check_installed
    
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}⚠️  Log file not found: $LOG_FILE${NC}"
        exit 1
    fi
    
    echo "Tailing logs from: $LOG_FILE"
    echo "Press Ctrl+C to exit"
    echo ""
    tail -f "$LOG_FILE"
}

show_version() {
    # Find the installed app bundle
    APP_PATH=""
    if [ -d "/Applications/MeetingScribe.app" ]; then
        APP_PATH="/Applications/MeetingScribe.app"
    elif [ -d "$HOME/Applications/MeetingScribe.app" ]; then
        APP_PATH="$HOME/Applications/MeetingScribe.app"
    fi
    
    if [ -z "$APP_PATH" ]; then
        echo -e "${RED}❌ MeetingScribe.app not found in /Applications or ~/Applications${NC}"
        exit 1
    fi
    
    # Read version from Info.plist
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    if [ ! -f "$INFO_PLIST" ]; then
        echo -e "${RED}❌ Info.plist not found at $INFO_PLIST${NC}"
        exit 1
    fi
    
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null)
    
    if [ -z "$VERSION" ]; then
        echo -e "${RED}❌ Could not read version from Info.plist${NC}"
        exit 1
    fi
    
    echo "MeetingScribe $VERSION"
    echo "Location: $APP_PATH"
}

# Main command dispatcher
case "${1:-}" in
    start)
        daemon_start
        ;;
    stop)
        daemon_stop
        ;;
    restart)
        daemon_restart
        ;;
    status)
        daemon_status
        ;;
    logs)
        daemon_logs
        ;;
    version)
        show_version
        ;;
    *)
        print_usage
        ;;
esac
