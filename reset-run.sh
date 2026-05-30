#!/bin/bash
################################################################################
# reset-run.sh - Cleanup helper for an AutoSlurm work directory
#
# Removes iteration folders and chain/output logs so a run can start cleanly.
#
# Usage:
#   ./reset-run.sh --workdir /path/to/job [--from-iter N]
#                  [--log-dir /path/to/job/logs]
#                  [--mirror-log-dir /path/to/autoslurm/logs] [--yes]
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
LOG_DIR=""
MIRROR_LOG_DIR="${SCRIPT_DIR}/logs"
FROM_ITER=""
AUTO_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)
            WORK_DIR="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --mirror-log-dir)
            MIRROR_LOG_DIR="$2"
            shift 2
            ;;
        --from-iter)
            FROM_ITER="$2"
            shift 2
            ;;
        --yes|-y)
            AUTO_YES=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --workdir /path/to/job [--from-iter N] [--log-dir /path/to/job/logs] [--mirror-log-dir /path/to/autoslurm/logs] [--yes]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ! -d "$WORK_DIR" ]]; then
    echo "Error: workdir does not exist: $WORK_DIR"
    exit 1
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="${WORK_DIR}/logs"
elif [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="${WORK_DIR}/${LOG_DIR}"
fi

if [[ "$MIRROR_LOG_DIR" != /* ]]; then
    MIRROR_LOG_DIR="${SCRIPT_DIR}/${MIRROR_LOG_DIR}"
fi

if [[ -n "$FROM_ITER" ]]; then
    if ! [[ "$FROM_ITER" =~ ^[0-9]+$ ]] || [[ "$FROM_ITER" -lt 1 ]]; then
        echo "Error: --from-iter must be an integer >= 1"
        exit 1
    fi
fi

JOB_TAG="$(basename "$WORK_DIR" | tr -cs 'A-Za-z0-9._-' '_')"

shopt -s nullglob

targets=()

# Iteration directories.
for p in "$WORK_DIR"/iteration-*; do
    base="$(basename "$p")"
    if [[ "$base" =~ ^iteration-([0-9]+)(-retry)?$ ]]; then
        n="${BASH_REMATCH[1]}"
        if [[ -z "$FROM_ITER" || "$n" -ge "$FROM_ITER" ]]; then
            targets+=("$p")
        fi
    fi
done

# Always remove chain logs and root job logs for a clean monitor state.
for p in "$WORK_DIR"/chain_*.log "$WORK_DIR"/job.*.out "$WORK_DIR"/job.*.err; do
    targets+=("$p")
done

if [[ -d "$LOG_DIR" ]]; then
    for p in "$LOG_DIR"/chain_*.log "$LOG_DIR"/launcher_*.log; do
        targets+=("$p")
    done
fi

if [[ -d "$MIRROR_LOG_DIR" ]]; then
    for p in "$MIRROR_LOG_DIR"/chain_"$JOB_TAG"_*.log; do
        targets+=("$p")
    done
fi

# Full reset (or from iteration 1): remove dynamic carry-over files in workdir.
if [[ -z "$FROM_ITER" || "$FROM_ITER" -le 1 ]]; then
    for p in "$WORK_DIR"/POSCAR "$WORK_DIR"/WAVECAR "$WORK_DIR"/CHGCAR; do
        targets+=("$p")
    done
fi

# De-duplicate and keep only existing paths.
existing=()
existing_count=0
declare -A seen
if (( ${#targets[@]} > 0 )); then
    for t in "${targets[@]}"; do
        if [[ -e "$t" ]]; then
            if [[ -z "${seen[$t]:-}" ]]; then
                existing+=("$t")
                seen[$t]=1
                existing_count=$((existing_count + 1))
            fi
        fi
    done
fi

if [[ "$existing_count" -eq 0 ]]; then
    echo "Nothing to clean."
    exit 0
fi

echo "Cleanup targets:"
for t in "${existing[@]}"; do
    echo "  $t"
done

if [[ "$AUTO_YES" -ne 1 ]]; then
    read -r -p "Proceed with deletion? [y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

for t in "${existing[@]}"; do
    if [[ -d "$t" ]]; then
        rm -rf "$t"
    else
        rm -f "$t"
    fi
done

echo "Cleanup complete."