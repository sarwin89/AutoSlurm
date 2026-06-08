#!/bin/bash
################################################################################
# heartbeat-test.sh - Minimal long-running logger for server lifetime testing
#
# Usage:
#   nohup ./heartbeat-test.sh &
#   nohup ./heartbeat-test.sh --interval 1800 --log-dir ./logs &
################################################################################

set -euo pipefail

INTERVAL=1800
LOG_DIR="$(pwd)/logs"
LOG_FILE=""

print_usage() {
    echo "Usage: $0 [--interval SECONDS] [--log-dir PATH] [--log-file PATH]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
    echo "Error: --interval must be an integer >= 1"
    exit 1
fi

if [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="$(pwd)/$LOG_DIR"
fi

mkdir -p "$LOG_DIR"

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="${LOG_DIR}/heartbeat_$(date '+%Y%m%d_%H%M%S').log"
elif [[ "$LOG_FILE" != /* ]]; then
    LOG_FILE="$(pwd)/$LOG_FILE"
fi

log_msg() {
    local msg="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp]  $msg" | tee -a "$LOG_FILE"
}

handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    trap - HUP INT TERM QUIT PIPE
    log_msg "Received ${signal_name}; heartbeat logger is exiting"
    exit "$exit_code"
}

trap 'handle_signal SIGHUP 129' HUP
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGQUIT 131' QUIT
trap 'handle_signal SIGPIPE 141' PIPE
trap 'handle_signal SIGTERM 143' TERM

log_msg "Heartbeat logger started"
log_msg "PID: $$"
log_msg "Interval: ${INTERVAL} seconds"
log_msg "Log file: $LOG_FILE"

while true; do
    sleep "$INTERVAL"
    log_msg "Heartbeat alive"
done
