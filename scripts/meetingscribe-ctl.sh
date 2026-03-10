#!/bin/bash

# MeetingScribe Daemon Control Script
# Usage: meetingscribe-ctl {start|stop|restart|status|logs}

set -e

PLIST="$HOME/Library/LaunchAgents/com.meetingscribe.daemon.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.meetingscribe.daemon"
LOG_FILE="$HOME/Library/Logs/MeetingScribe/stderr.log"
SPEAKER_DB="$HOME/.meetingscribe/speaker.db"

# Find Python and scripts
APP_PATH=""
if [ -d "/Applications/MeetingScribe.app" ]; then
    APP_PATH="/Applications/MeetingScribe.app"
elif [ -d "$HOME/Applications/MeetingScribe.app" ]; then
    APP_PATH="$HOME/Applications/MeetingScribe.app"
fi

SCRIPTS_DIR="${APP_PATH:+$APP_PATH/Contents/Resources/scripts}"
PYTHON_BIN="${APP_PATH:+$APP_PATH/Contents/Resources/python/bin/python3}"

# Fallback for development - check if speaker_cli.py actually exists in the app bundle
if [ -z "$SCRIPTS_DIR" ] || [ ! -f "$SCRIPTS_DIR/speaker_cli.py" ]; then
    # Try to find scripts relative to this script
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/speaker_cli.py" ]; then
        SCRIPTS_DIR="$SCRIPT_DIR"
    fi
fi

if [ -z "$PYTHON_BIN" ] || [ ! -f "$PYTHON_BIN" ]; then
    PYTHON_BIN=$(which python3 2>/dev/null)
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_usage() {
    echo -e "${BOLD}Usage:${NC} meetingscribe-ctl <command> [options]"
    echo ""
    echo -e "${BOLD}Daemon Commands:${NC}"
    echo "  start              Start the MeetingScribe daemon"
    echo "  stop               Stop the MeetingScribe daemon"
    echo "  restart            Restart the MeetingScribe daemon"
    echo "  status             Check if daemon is running"
    echo "  logs               View daemon logs (tail -f)"
    echo "  version            Show installed version"
    echo ""
    echo -e "${BOLD}Speaker Commands:${NC}"
    echo "  speakers list      List all known speakers"
    echo "  speakers pending   Show pending name confirmations"
    echo "  speakers confirm   Confirm a pending name suggestion"
    echo "  speakers reject    Reject a pending name suggestion"
    echo "  speakers rename    Manually set a speaker's name"
    echo "  speakers merge     Merge duplicate speakers"
    echo "  speakers split     Split incorrectly merged speaker"
    echo "  speakers delete    Delete a speaker"
    echo "  speakers stats     Show database statistics"
    echo "  speakers cleanup   Run database maintenance"
    echo ""
    echo -e "Run ${BOLD}meetingscribe-ctl speakers --help${NC} for detailed speaker commands."
    exit 1
}

print_speakers_usage() {
    echo -e "${BOLD}Usage:${NC} meetingscribe-ctl speakers <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  list                          List all known speakers"
    echo "  pending                       Show pending name confirmations"
    echo "  confirm <suggestion_id>       Accept a name suggestion"
    echo "  reject <suggestion_id>        Reject a name suggestion"
    echo "  show <speaker_id>             Show details for a speaker"
    echo "  rename <speaker_id> <name>    Set speaker name manually"
    echo "  merge <keep_id> <merge_id>    Merge two speakers (keeps first)"
    echo "  split <speaker_id> <emb_ids>  Split incorrectly merged speaker"
    echo "  delete <speaker_id>           Delete a speaker permanently"
    echo "  stats                         Show database statistics"
    echo "  cleanup                       Run database maintenance"
    echo "  check                         Run integrity checks"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --json                        Output in JSON format"
    echo "  --db <path>                   Use alternate database path"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  meetingscribe-ctl speakers pending"
    echo "  meetingscribe-ctl speakers confirm abc123-def456"
    echo "  meetingscribe-ctl speakers rename spk_789 \"John Smith\""
    echo "  meetingscribe-ctl speakers merge spk_123 spk_456"
    exit 1
}

check_speaker_cli() {
    if [ -z "$SCRIPTS_DIR" ] || [ ! -f "$SCRIPTS_DIR/speaker_cli.py" ]; then
        echo -e "${RED}❌ Speaker CLI not found${NC}"
        echo ""
        echo "This feature requires MeetingScribe with Smart Prompts support."
        if [ -n "$SCRIPTS_DIR" ]; then
            echo "Expected at: $SCRIPTS_DIR/speaker_cli.py"
        else
            echo "Could not determine scripts directory."
            echo "Ensure MeetingScribe.app is installed in /Applications or ~/Applications."
        fi
        exit 1
    fi
    
    if [ -z "$PYTHON_BIN" ] || [ ! -f "$PYTHON_BIN" ]; then
        echo -e "${RED}❌ Python not found${NC}"
        echo ""
        echo "Could not find Python 3. Please ensure Python 3 is installed."
        exit 1
    fi
}

run_speaker_cli() {
    "$PYTHON_BIN" "$SCRIPTS_DIR/speaker_cli.py" --db "$SPEAKER_DB" "$@"
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
    
    # Check if process is already running
    if ps aux | grep -v grep | grep -q "/Applications/MeetingScribe.app/Contents/MacOS/meetingscribe"; then
        echo -e "${YELLOW}⚠️  Daemon is already running${NC}"
        return 0
    fi
    
    # Check if service is loaded
    if ! launchctl list | grep -q "$LABEL"; then
        echo "Loading MeetingScribe daemon..."
        launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || {
            echo -e "${RED}❌ Failed to load daemon${NC}"
            exit 1
        }
    fi
    
    echo "Starting MeetingScribe daemon..."
    launchctl kickstart -kp "$DOMAIN/$LABEL" 2>&1
    
    sleep 3
    
    # Check if process is actually running
    if pgrep -f "/Applications/MeetingScribe.app/Contents/MacOS/meetingscribe" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Daemon started successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  Daemon may have started but process not found (check logs)${NC}"
    fi
}

daemon_stop() {
    check_installed
    
    if ! launchctl list | grep -q "$LABEL"; then
        echo -e "${YELLOW}⚠️  Daemon is not running${NC}"
        return 0
    fi
    
    echo "Stopping MeetingScribe daemon..."
    # Use kill to stop the process without unloading the service
    launchctl kill SIGTERM "$DOMAIN/$LABEL" 2>/dev/null || true
    
    # Wait for process to stop
    sleep 2
    
    # Verify it stopped by checking if there's a PID
    if launchctl list | grep "$LABEL" | grep -q "^-"; then
        echo -e "${GREEN}✅ Daemon stopped successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  Daemon may still be running (KeepAlive will restart it)${NC}"
        echo -e "${YELLOW}    To fully disable, run: launchctl bootout $DOMAIN $PLIST${NC}"
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

# ─────────────────────────────────────────────────────────────────────
# Speaker Commands
# ─────────────────────────────────────────────────────────────────────

speakers_command() {
    local subcommand="${1:-}"
    
    if [ -z "$subcommand" ] || [ "$subcommand" = "--help" ] || [ "$subcommand" = "-h" ]; then
        print_speakers_usage
    fi
    
    check_speaker_cli
    
    # Check DB exists (except for stats/check which handle missing DB gracefully)
    if [ ! -f "$SPEAKER_DB" ] && [ "$subcommand" != "stats" ] && [ "$subcommand" != "check" ]; then
        echo -e "${YELLOW}⚠️  Speaker database not found${NC}"
        echo ""
        echo "The speaker database is created automatically when Smart Prompts"
        echo "processes its first meeting. No speakers have been recorded yet."
        echo ""
        echo "To enable Smart Prompts:"
        echo "  1. Open MeetingScribe Settings"
        echo "  2. Go to Transcription → Smart Prompts"
        echo "  3. Enable 'Use speaker-aware prompts'"
        exit 1
    fi
    
    # Map friendly command names to CLI commands
    case "$subcommand" in
        list)
            shift
            run_speaker_cli list-speakers "$@"
            ;;
        pending)
            shift
            run_speaker_cli list-pending "$@"
            ;;
        confirm)
            shift
            if [ -z "$1" ]; then
                echo -e "${RED}Error: Missing suggestion_id${NC}"
                echo "Usage: meetingscribe-ctl speakers confirm <suggestion_id>"
                exit 1
            fi
            run_speaker_cli confirm "$@"
            ;;
        reject)
            shift
            if [ -z "$1" ]; then
                echo -e "${RED}Error: Missing suggestion_id${NC}"
                echo "Usage: meetingscribe-ctl speakers reject <suggestion_id>"
                exit 1
            fi
            run_speaker_cli reject "$@"
            ;;
        show|info|get)
            shift
            if [ -z "$1" ]; then
                echo -e "${RED}Error: Missing speaker_id${NC}"
                echo "Usage: meetingscribe-ctl speakers show <speaker_id>"
                exit 1
            fi
            run_speaker_cli get-speaker "$@"
            ;;
        rename|name)
            shift
            if [ -z "$1" ] || [ -z "$2" ]; then
                echo -e "${RED}Error: Missing arguments${NC}"
                echo "Usage: meetingscribe-ctl speakers rename <speaker_id> <name>"
                exit 1
            fi
            run_speaker_cli rename "$@"
            ;;
        merge)
            shift
            if [ -z "$1" ] || [ -z "$2" ]; then
                echo -e "${RED}Error: Missing arguments${NC}"
                echo "Usage: meetingscribe-ctl speakers merge <keep_id> <merge_id>"
                echo ""
                echo "The first speaker is kept, the second is merged into it and deleted."
                exit 1
            fi
            echo -e "${YELLOW}⚠️  This will merge speaker $2 into $1 and delete $2${NC}"
            read -p "Continue? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                run_speaker_cli merge --force "$@"
            else
                echo "Cancelled."
                exit 0
            fi
            ;;
        split)
            shift
            if [ -z "$1" ] || [ -z "$2" ]; then
                echo -e "${RED}Error: Missing arguments${NC}"
                echo "Usage: meetingscribe-ctl speakers split <speaker_id> <embedding_id> [embedding_id...]"
                exit 1
            fi
            local speaker_id="$1"
            shift
            echo -e "${YELLOW}⚠️  This will split $# embeddings from speaker $speaker_id into a new speaker${NC}"
            read -p "Continue? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                run_speaker_cli split --force "$speaker_id" "$@"
            else
                echo "Cancelled."
                exit 0
            fi
            ;;
        delete|rm|remove)
            shift
            if [ -z "$1" ]; then
                echo -e "${RED}Error: Missing speaker_id${NC}"
                echo "Usage: meetingscribe-ctl speakers delete <speaker_id>"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  This will permanently delete speaker $1 and all associated data${NC}"
            read -p "Continue? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                run_speaker_cli delete --force "$@"
            else
                echo "Cancelled."
                exit 0
            fi
            ;;
        stats)
            shift
            run_speaker_cli stats "$@"
            ;;
        cleanup)
            shift
            echo "Running database cleanup..."
            run_speaker_cli cleanup "$@"
            ;;
        check)
            shift
            run_speaker_cli check "$@"
            ;;
        *)
            echo -e "${RED}Unknown speakers command: $subcommand${NC}"
            print_speakers_usage
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────
# Main Command Dispatcher
# ─────────────────────────────────────────────────────────────────────

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
    speakers|speaker)
        shift
        speakers_command "$@"
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        print_usage
        ;;
esac
