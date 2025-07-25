#!/bin/bash

set -u

# Enable nullglob so globs that match nothing expand to zero words
shopt -s nullglob

# === Configuration ===
TUPPLEDIR="${LINDA_DIR:-/tmp/linda}"
LOCKEXT=".lock"
LOCK_TIMEOUT=5  # seconds to wait for lock before giving up

# === Locking with PID check and timeout ===
filelock() {
    local lockname="$1"
    local lockpath="$lockname$LOCKEXT"
    local start now pid

    start=$(date +%s)
    while true; do
        if ( set -o noclobber; echo "$$" > "$lockpath" ) 2>/dev/null; then
            return 0  # Lock acquired
        fi

        if [ -f "$lockpath" ]; then
            pid=$(cat "$lockpath" 2>/dev/null || echo "")
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                if ! kill -0 "$pid" 2>/dev/null; then
                    rm -f "$lockpath"
                    echo "Removed stale lock held by PID $pid" >&2
                    continue
                fi
            else
                rm -f "$lockpath"
                echo "Removed corrupt lock file" >&2
                continue
            fi
        fi

        sleep 0.05
        now=$(date +%s)
        if (( now - start >= LOCK_TIMEOUT )); then
            echo "Timeout acquiring lock $lockpath" >&2
            return 1
        fi
    done
}

fileunlock() {
    local lockname="$1"
    rm -f "$lockname$LOCKEXT"
}

clean_expired() {
    for f in "$TUPPLEDIR"/*.*; do
        local expires="${f##*.}"
        if [[ "$expires" =~ ^[0-9]+$ ]]; then
            if [[ "$expires" -le $(date +%s) ]]; then
                rm -f "$f"
            fi
        fi
    done
}

# === FIFO sequence ===
next_seq() {
    local name="$1"
    local seqfile="$TUPPLEDIR/.$name.seq"
    filelock "$seqfile" || {
        echo "Failed to acquire sequence lock for $name" >&2
        return 1
    }

    local seq=0
    if [ -f "$seqfile" ]; then
        seq=$(< "$seqfile")
    fi
    printf "%08d" $((10#$seq + 1)) > "$seqfile"
    fileunlock "$seqfile"
    printf -- "-%08d" $((10#$seq))
}

hex() {
    local bytes=${1-4}
    local prefix=${2-}

    rand=$(head -c $bytes /dev/random | od -An -t x$bytes)
    rand=${rand// /}
    echo "$prefix$rand"
}

# === Atomic read-and-consume operation ===
_try_read_tuple_atomic() {
    local name="$1"
    local consume="$2"  # "consume" or "read"
    local retry_count=0
    
    while [ "$retry_count" -lt 2 ]; do
        local found_any=0
        
        for f in "$TUPPLEDIR/$name"*; do
            found_any=1
            
            if [ "$consume" = "consume" ]; then
                # For consume operations, we need atomic read-and-delete
                #
                if filelock "$f"; then
                    if cat "$f" 2>/dev/null; then
                        # Successfully read, now delete
                        rm -f "$f"
                        fileunlock "$f"
                        return 0
                    fi
                    fileunlock "$f"
                fi
                # Lock failed or file disappeared, try next file
            else
                if cat "$f" 2>/dev/null; then
                    return 0
                fi
            fi
            
            # Lock failed or file disappeared, try next file
        done
        
        if [ "$found_any" -eq 0 ]; then
            return 1  # No files matched the pattern
        fi
        
        # All files in this glob were locked by others or disappeared, try one immediate re-glob
        retry_count=$((retry_count + 1))
    done
    
    return 1  # Give up after 2 attempts
}

# === Internal function to handle waiting/timeout logic ===
_wait_for_tuple() {
    local name="$1"
    local consume="$2"     # "consume" or "read"
    local mode="${3:-wait}" # wait | once | timeout_seconds
    
    local timeout=0
    local deadline=0
    local now
    
    if [[ "$mode" == "once" ]]; then
        timeout=0
    elif [[ "$mode" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
        deadline=$((now + mode))
        timeout=1
    fi

    while :; do
        if _try_read_tuple_atomic "$name" "$consume"; then
            return 0
        fi

        if [[ "$mode" == "once" ]]; then
            return 1
        elif [ "$timeout" -eq 1 ]; then
            now=$(date +%s)
            if [ "$now" -ge "$deadline" ]; then
                return 1
            fi
        fi
        sleep 0.1
    done
}

# === Command: out ===
cmd_out() {
    local name="$1"; shift
    local ttl=0
    local seq=""

    if [[ $# -gt 2 ]]; then
        echo "Too many arguments" >&2
        exit 1
    fi

    local hex="-$(hex)"
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "rep" ]]; then
            hex=""
        elif [[ "$1" == "seq" ]]; then
            seq=$(next_seq "$name") || exit 1
        elif [[ "$1" =~ ^[0-9]+$ ]]; then
            ttl=$1
        else
            echo "Invalid argument: $1" >&2
            exit 1
        fi
        shift
    done

    local expires=""
    if [ "$ttl" -gt 0 ]; then
        expires=".$(( $(date +%s) + ttl ))"
    fi

    local fname="$TUPPLEDIR/${name}${seq}${hex}${expires}"

    local tmp
    tmp=$(mktemp "$fname.tmp.XXXXXX")
    cat > "$tmp"
    mv "$tmp" "$fname"
}

# === Command: inp (consume) ===
cmd_inp() {
    local name="$1"
    local mode="${2:-wait}"
    _wait_for_tuple "$name" consume "$mode"
}

# === Command: rd (read without consuming) ===
cmd_rd() {
    local name="$1"
    local mode="${2:-wait}"
    _wait_for_tuple "$name" read "$mode"
}

cmd_ls() {
    local name="${1-}"
    for f in "$TUPPLEDIR/$name"*; do
        echo "$(basename "${f%%-*}")"
    done | sort | uniq -c
}

cmd_clear() {
    rm -f "$TUPPLEDIR/"*
    rm -f "$TUPPLEDIR/".*.seq
    rm -f "$TUPPLEDIR/".*.lock
}

# === Run ===
mkdir -p "$TUPPLEDIR"
clean_expired

cmd="${1:-}"
shift || true

case "$cmd" in
    out)   cmd_out "$@" ;;
    inp)   cmd_inp "$@" ;;
    rd)    cmd_rd "$@" ;;
    ls)    cmd_ls "$@" ;;
    clear) cmd_clear ;;
    *) echo "Usage: $0 {out|inp|rd|ls|clear} ..." >&2; exit 1 ;;
esac
