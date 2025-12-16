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
    echo "Usage: meetingscribe-ctl {start|stop|restart|status|logs}"
    echo ""
    echo "Commands:"
    echo "  start    - Start the MeetingScribe daemon"
    echo "  stop     - Stop the MeetingScribe daemon"
    echo "  restart  - Restart the MeetingScribe daemon"
    echo "  status   - Check if daemon is running"
    echo "  logs     - View daemon logs (tail -f)"
    exit 1
}

check_installed() {
    if [ ! -f "$PLIST" ]; then
        echo -e "${RED}❌ MeetingScribe is not installed${NC}"
        echo "Run: ./scripts/install.sh"
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
    *)
        print_usage
        ;;
esac
