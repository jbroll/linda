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
count=$($LINDA ls | grep -E '^[[:space:]]*1 seqtest$' || true)
[[ -n "$count" ]] && echo "PASS: Sequence format" || echo "FAIL: Sequence format: $count"

echo "== Test 4: TTL + Sequence =="
echo "combined" | $LINDA out both 5 seq
count=$($LINDA ls | grep -E '^[[:space:]]*1 both$' || true)
[[ -n "$count" ]] && echo "PASS: TTL+Seq format" || echo "FAIL: TTL+Seq format: $count"

echo "== Test 5: Read (rd) does not consume =="
echo "read me" | $LINDA out readtest
result1=$($LINDA rd readtest once)
result2=$($LINDA rd readtest once)
[[ "$result1" == "read me" && "$result2" == "read me" ]] && echo "PASS: rd returns same result" || echo "FAIL: rd does not behave"

echo "== Test 6: Listing keys =="
echo "one" | $LINDA out listme
echo "two" | $LINDA out listme
echo "three" | $LINDA out another
lsout=$($LINDA ls)
echo "$lsout" | grep -E -q '^[[:space:]]*2 listme$' && \
echo "$lsout" | grep -E -q '^[[:space:]]*1 another$' && \
echo "PASS: ls keys and counts" || echo "FAIL: ls missing keys"

echo "== Test 7: Cleanup expired tuples =="
echo "soon gone" | $LINDA out tempkey 1
sleep 2
expired=$($LINDA ls | grep -E 'tempkey' || true)
[[ -z "$expired" ]] && echo "PASS: Expired tuple not listed" || echo "FAIL: Expired tuple not deleted"

echo "== All tests complete =="
