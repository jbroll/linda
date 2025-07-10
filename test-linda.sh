#!/bin/bash
set -euo pipefail

LINDA="./linda.sh"
TUPPLEDIR="/tmp/linda-test"
export LINDA_DIR="$TUPPLEDIR"

mkdir -p "$TUPPLEDIR"
rm -f "$TUPPLEDIR"/* || true

echo "== Test 1: Basic out/inp =="
echo "hello" | $LINDA out test1
result=$($LINDA inp test1 once)
[[ "$result" == "hello" ]] && echo "PASS: Basic out/in" || echo "FAIL: Basic out/in"

echo "== Test 2: Expiry =="
echo "short-lived" | $LINDA out expireme 1
sleep 2
$LINDA inp expireme once && echo "FAIL: Tuple should be expired" || echo "PASS: Tuple expired"

echo "== Test 3: Sequence numbering =="
echo "seq test" | $LINDA out seqtest seq
file=$($LINDA ls seqtest)
[[ "$file" =~ ^seqtest-[0-9]{8}-[a-z0-9]{6}$ ]] && echo "PASS: Sequence format" || echo "FAIL: Sequence format: $file"

echo "== Test 4: TTL + Sequence =="
echo "combined" | $LINDA out both 5 seq
file=$($LINDA ls both)
[[ "$file" =~ ^both-[0-9]{8}-[a-z0-9]{6}\.[0-9]+$ ]] && echo "PASS: TTL+Seq format" || echo "FAIL: TTL+Seq format: $file"

echo "== Test 5: Read (rd) does not consume =="
echo "peekaboo" | $LINDA out peek
first=$($LINDA rd peek)
second=$($LINDA rd peek)
[[ "$first" == "$second" ]] && echo "PASS: rd returns same result" || echo "FAIL: rd mismatch"

echo "== Test 6: Listing keys =="
echo "alpha" | $LINDA out key1
echo "beta" | $LINDA out key2
keys=$($LINDA ls)
[[ "$keys" == *"key1"* && "$keys" == *"key2"* ]] && echo "PASS: ls shows keys" || echo "FAIL: ls missing keys"

echo "== Test 7: Cleanup expired tuples =="
echo "old" | $LINDA out willdie 1
sleep 2
$LINDA ls willdie > /dev/null 2>&1 && echo "FAIL: Expired tuple not deleted" || echo "PASS: Expired tuple cleaned"

echo "== All tests complete =="
