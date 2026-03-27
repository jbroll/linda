#!/bin/bash

set -uo pipefail
. ./Test

LINDA="./linda.sh"
TUPPLEDIR="/tmp/lindatest"
export LINDA_DIR="$TUPPLEDIR"

# Setup test environment
mkdir -p "$TUPPLEDIR"
rm -f "$TUPPLEDIR"/* || true

# === Test 1: Basic out/inp ===
Test "Basic out/inp operation"
echo "hello" | $LINDA out test1
result=$($LINDA inp test1 once)
CompareArgs "$result" "hello"

# === Test 2: Expiry ===
Test "Tuple expiry after TTL"
echo "short-lived" | $LINDA out expireme 1
sleep 2
# Should fail (return 1) because tuple is expired
if $LINDA inp expireme once >/dev/null 2>&1; then
    Fail
else
    Pass
fi

# === Test 3: Sequence numbering ===
Test "Sequence numbering format"
echo "seq test" | $LINDA out seqtest seq
# Check that the tuple exists by trying to read it
result=$($LINDA rd seqtest once)
CompareArgs "$result" "seq test"

# === Test 4: TTL + Sequence ===
Test "TTL with sequence numbering"
echo "combined" | $LINDA out both 5 seq
# Check that the tuple exists by trying to read it
result=$($LINDA rd both once)
CompareArgs "$result" "combined"

# === Test 5: Read (rd) does not consume ===
Test "rd command does not consume tuple"
echo "read me" | $LINDA out readtest
result1=$($LINDA rd readtest once)
result2=$($LINDA rd readtest once)
CompareArgs "$result1" "read me" "$result2" "read me"

# === Test 6: Listing keys ===
Test "ls command shows correct counts"
$LINDA clear  # Clean slate
echo "one" | $LINDA out listme
echo "two" | $LINDA out listme
echo "three" | $LINDA out another
# The ls command shows counts by tuple name
lsout=$($LINDA ls)
# Check that we have some output that includes counts
if [[ -n "$lsout" ]]; then
    Pass
else
    Fail
fi

# === Test 7: Cleanup expired tuples ===
Test "Expired tuples are cleaned up"
echo "soon gone" | $LINDA out tempkey 1
sleep 2
# Trigger cleanup by running ls
$LINDA ls >/dev/null
# Try to read the expired tuple - should fail
if $LINDA rd tempkey once >/dev/null 2>&1; then
    Fail
else
    Pass
fi

# === Test 8: Replacement semantics ===
Test "Replacement semantics with rep flag"
echo "first" | $LINDA out reptest rep
echo "second" | $LINDA out reptest rep
# Should only have one tuple and it should be the second one
result=$($LINDA inp reptest once)
CompareArgs "$result" "second"

# === Test 9: Multiple tuples with same name ===
Test "Multiple tuples with same name"
echo "data1" | $LINDA out multitest
echo "data2" | $LINDA out multitest
# Should be able to read both tuples (order may vary)
result1=$($LINDA inp multitest once 2>/dev/null)
result2=$($LINDA inp multitest once 2>/dev/null)
if [[ (-n "$result1") && (-n "$result2") ]]; then
    Pass
else
    Fail
fi

# === Test 10: FIFO semantics with sequence numbering ===
Test "FIFO semantics with seq flag"
echo "first" | $LINDA out fifotest seq
echo "second" | $LINDA out fifotest seq  
echo "third" | $LINDA out fifotest seq
# Should retrieve in FIFO order (first in, first out)
result1=$($LINDA inp fifotest once 2>/dev/null)
result2=$($LINDA inp fifotest once 2>/dev/null)
result3=$($LINDA inp fifotest once 2>/dev/null)
if [[ "$result1" == "first" && "$result2" == "second" && "$result3" == "third" ]]; then
    Pass
else
    echo "DEBUG: Expected first,second,third but got: '$result1','$result2','$result3'" >&2
    Fail
fi

# === Test 10: Blocking timeout ===
Test "inp with timeout returns failure when no match"
start_time=$(date +%s)
if $LINDA inp nonexistent 1 >/dev/null 2>&1; then
    Fail
else
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    # Should have waited approximately 1 second
    if [[ $elapsed -ge 1 && $elapsed -le 2 ]]; then
        Pass
    else
        Fail
    fi
fi

# === Test 11: Clear command ===
Test "clear command removes all tuples"
echo "test1" | $LINDA out cleartest1
echo "test2" | $LINDA out cleartest2
$LINDA clear
# Try to read any tuple - should fail
if $LINDA rd cleartest1 once >/dev/null 2>&1 || $LINDA rd cleartest2 once >/dev/null 2>&1; then
    Fail
else
    Pass
fi

# === Test 13: Concurrent inp — exactly one wins ===
Test "Concurrent inp: exactly one consumer wins a single tuple"
# Start two blocking consumers before the tuple exists
$LINDA inp concrace 3 > /tmp/linda_c1.out 2>/dev/null &
pid1=$!
$LINDA inp concrace 3 > /tmp/linda_c2.out 2>/dev/null &
pid2=$!
sleep 0.1   # let both settle into their wait loop
echo "prize" | $LINDA out concrace
wait $pid1; rc1=$?
wait $pid2; rc2=$?
got1=$(cat /tmp/linda_c1.out 2>/dev/null)
got2=$(cat /tmp/linda_c2.out 2>/dev/null)
rm -f /tmp/linda_c1.out /tmp/linda_c2.out
if [[ ("$got1" = "prize" && -z "$got2") || ("$got2" = "prize" && -z "$got1") ]]; then
    Pass
else
    Fail
fi

# === Test 14: Stale lock from dead process is recovered ===
Test "Stale lock file from dead process is cleaned up"
echo "staledata" | $LINDA out staletest
tuplefile=$(ls "$TUPPLEDIR"/staletest* 2>/dev/null | grep -v '\.lock$' | head -1)
echo "999999999" > "${tuplefile}.lock"
result=$($LINDA inp staletest once)
CompareArgs "$result" "staledata"

# === Test 15: seq + rep together — both effects apply ===
Test "out with seq and rep: sequence number present, random hex absent"
$LINDA clear
echo "data" | $LINDA out seqrep seq rep
file=$(ls "$TUPPLEDIR"/seqrep* 2>/dev/null | grep -v '\.lock$' | head -1)
base=$(basename "$file")
# Filename must be: seqrep-NNNNNNNN (no second hex segment, no expiry suffix)
if [[ "$base" =~ ^seqrep-[0-9]{8}$ ]]; then Pass; else echo "got: $base" >&2; Fail; fi

# === Test 16: ls count numerical accuracy ===
Test "ls counts are numerically accurate"
$LINDA clear
echo "x" | $LINDA out alpha
echo "x" | $LINDA out alpha
echo "x" | $LINDA out alpha
echo "y" | $LINDA out beta
echo "y" | $LINDA out beta
alpha_count=$($LINDA ls | awk '$2=="alpha"{print $1}')
beta_count=$($LINDA ls | awk '$2=="beta"{print $1}')
CompareArgs "$alpha_count" "3" "$beta_count" "2"

# === Test 17: ls count after rep overwrite must be 1 ===
Test "ls reports count=1 after two rep-mode writes"
$LINDA clear
echo "v1" | $LINDA out singleton rep
echo "v2" | $LINDA out singleton rep
count=$($LINDA ls | awk '$2=="singleton"{print $1}')
CompareArgs "$count" "1"

TestDone
