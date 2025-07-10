#!/bin/bash
# linda.sh - Minimal Linda tuple space using files, TTL, native locking, and in-timeout

TUPLEDIR="${LINDA_DIR:-/tmp/linda}"
LOCKFILE="$TUPLEDIR/.lock.cleanup"

mkdir -p "$TUPLEDIR"

# --- File-based lock function ---
filelock() {
  local name="$1"
  local lockfile="$TUPLEDIR/.lock.$name"
  # Try atomic link for lock
  if ln "$0" "$lockfile" 2>/dev/null; then
    echo "$$" > "$lockfile.pid"
    return 0
  else
    return 1
  fi
}

# --- Cleanup expired tuples if we get the lock ---
if filelock "cleanup"; then
  trap 'rm -f "$TUPLEDIR/.lock.cleanup" "$TUPLEDIR/.lock.cleanup.pid"' EXIT
  now=$(date +%s)

  for file in "$TUPLEDIR"/*; do
    [[ -e "$file" ]] || continue
    exp=$(echo "$file" | awk -F. '{print $(NF-2)}')
    [[ "$exp" =~ ^[0-9]+$ ]] || continue
    [[ "$exp" == "0" ]] && continue
    if [[ "$now" -ge "$exp" ]]; then
      rm -f "$file" "$file.lock"
    fi
  done
fi

# --- Helper functions ---
usage() {
  echo "Usage:"
  echo "  echo '{...}' | $0 out name [ttl_seconds]"
  echo "  $0 inp name-or-pattern [once|timeout]"
  echo "  $0 rd name-or-pattern"
  echo "  $0 ls [name-or-pattern]"
  exit 1
}

is_expired() {
  local fname="$1"
  local exp=$(echo "$fname" | awk -F. '{print $(NF-2)}')
  [[ "$exp" == "0" ]] && return 1
  [[ "$(date +%s)" -ge "$exp" ]]
}

# --- Main command dispatch ---
op="$1"
pattern="$2"
third="$3"

case "$op" in
  out)
    [[ -z "$pattern" ]] && usage
    if [[ "$third" =~ ^[0-9]+$ && "$third" -gt 0 ]]; then
      expiry=$(( $(date +%s) + third ))
    else
      expiry=0
    fi
    rand=$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)
    file="$TUPLEDIR/$pattern.$expiry.$rand"
    tmp=$(mktemp "$TUPLEDIR/tmp.$pattern.XXXXXX") || exit 1
    cat > "$tmp"
    mv "$tmp" "$file"
    ;;

  inp)
    [[ -z "$pattern" ]] && usage
    shopt -s nullglob

    mode="block"
    timeout=0

    if [[ -n "$third" ]]; then
      if [[ "$third" == "once" ]]; then
        mode="once"
      elif [[ "$third" =~ ^[0-9]+$ ]]; then
        mode="timeout"
        timeout=$third
      else
        usage
      fi
    fi

    start_time=$(date +%s)
    while true; do
      for file in "$TUPLEDIR"/$pattern*; do
        is_expired "$file" && continue
        lock="$file.lock"
        if ln "$file" "$lock" 2>/dev/null; then
          cat "$file"
          rm -f "$file" "$lock"
          exit 0
        fi
      done

      if [[ "$mode" == "once" ]]; then
        exit 1
      elif [[ "$mode" == "timeout" ]]; then
        now=$(date +%s)
        elapsed=$((now - start_time))
        if (( elapsed >= timeout )); then
          exit 1
        fi
      fi

      sleep 0.1
    done
    ;;

  rd)
    [[ -z "$pattern" ]] && usage
    shopt -s nullglob
    while true; do
      for file in "$TUPLEDIR"/$pattern*; do
        is_expired "$file" && continue
        lock="$file.lock"
        if ln "$file" "$lock" 2>/dev/null; then
          cat "$file"
          rm -f "$lock"
          exit 0
        fi
      done
      sleep 0.1
    done
    ;;

  ls)
    shopt -s nullglob
    pat="${pattern:-*}"
    for file in "$TUPLEDIR"/$pat*; do
      is_expired "$file" && continue
      basename "$file"
    done
    ;;

  *)
    usage
    ;;
esac
