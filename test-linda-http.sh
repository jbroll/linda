#!/bin/bash
# HTTP API tests for linda-http.tcl
#
# Requires wapp.tcl and wapp-routes.tcl in the working directory.
# Download wapp from https://wapp.tcl.tk/ and place wapp.tcl here.
# wapp-routes.tcl is a companion file that must also be present.
#
# Usage: ./test-linda-http.sh

set -uo pipefail
. ./Test

PORT=18765
LINDA_DIR=$(mktemp -d)
export LINDA_DIR
BASE="http://127.0.0.1:$PORT"
SERVER_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$LINDA_DIR"
}
trap cleanup EXIT

# === Dependency check ===
if [[ ! -f wapp.tcl || ! -f wapp-routes.tcl ]]; then
    echo "SKIP: wapp.tcl and/or wapp-routes.tcl not found." >&2
    echo "      Download wapp from https://wapp.tcl.tk/ to run HTTP tests." >&2
    exit 0
fi

# === Start server ===
LINDA_DIR="$LINDA_DIR" tclsh linda-http.tcl -local "$PORT" &
SERVER_PID=$!

# Wait up to 5 seconds for the server to be ready
for i in $(seq 1 50); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -sf "$BASE/health" >/dev/null 2>&1; then
    echo "ERROR: Server did not start on port $PORT" >&2
    exit 1
fi

# === Helper ===
http_code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

# === Test H1: Health endpoint ===
Test "GET /health returns healthy status"
resp=$(curl -sf "$BASE/health")
if echo "$resp" | grep -q '"status".*"healthy"'; then Pass; else Fail; fi

# === Test H2: Store and retrieve a tuple ===
Test "POST then GET /tuples/{name} round-trips data"
curl -sf -X POST "$BASE/tuples/mykey" -d "hello http" >/dev/null
resp=$(curl -sf "$BASE/tuples/mykey")
if echo "$resp" | grep -q '"success":.*true' && echo "$resp" | grep -q 'hello http'; then Pass; else Fail; fi

# === Test H3: GET non-existent tuple returns 404 ===
Test "GET /tuples/{name} returns 404 when absent"
code=$(http_code "$BASE/tuples/doesnotexist")
CompareArgs "$code" "404"

# === Test H4: DELETE consumes the tuple ===
Test "DELETE /tuples/{name} consumes the tuple"
curl -sf -X POST "$BASE/tuples/consume_me" -d "one-time" >/dev/null
resp=$(curl -sf -X DELETE "$BASE/tuples/consume_me")
if ! echo "$resp" | grep -q 'one-time'; then Fail
else
    code=$(http_code -X DELETE "$BASE/tuples/consume_me")
    CompareArgs "$code" "404"
fi

# === Test H5: POST with TTL — tuple expires ===
Test "POST with ttl=1 causes tuple to expire"
curl -sf -X POST "$BASE/tuples/shortlived?ttl=1" -d "ephemeral" >/dev/null
sleep 2
code=$(http_code "$BASE/tuples/shortlived")
CompareArgs "$code" "404"

# === Test H6: POST with mode=rep — replacement semantics ===
Test "POST with mode=rep replaces existing tuple"
curl -sf -X POST "$BASE/tuples/repkey?mode=rep" -d "first" >/dev/null
curl -sf -X POST "$BASE/tuples/repkey?mode=rep" -d "second" >/dev/null
resp=$(curl -sf "$BASE/tuples/repkey")
if echo "$resp" | grep -q 'second'; then Pass; else Fail; fi

# === Test H7: POST with mode=seq — FIFO order ===
Test "POST with mode=seq delivers tuples in FIFO order"
curl -sf -X POST "$BASE/tuples/fifo?mode=seq" -d "one" >/dev/null
curl -sf -X POST "$BASE/tuples/fifo?mode=seq" -d "two" >/dev/null
r1=$(curl -sf -X DELETE "$BASE/tuples/fifo" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
r2=$(curl -sf -X DELETE "$BASE/tuples/fifo" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'])")
CompareArgs "$r1" "one" "$r2" "two"

# === Test H8: GET /tuples list endpoint ===
Test "GET /tuples lists stored tuple names"
curl -sf -X POST "$BASE/tuples/listed" -d "x" >/dev/null
resp=$(curl -sf "$BASE/tuples")
if echo "$resp" | grep -q '"success":.*true' && echo "$resp" | grep -q 'listed'; then Pass; else Fail; fi

# === Test H9: DELETE /tuples clears all tuples ===
Test "DELETE /tuples clears all tuples"
curl -sf -X POST "$BASE/tuples/gone1" -d "a" >/dev/null
curl -sf -X POST "$BASE/tuples/gone2" -d "b" >/dev/null
curl -sf -X DELETE "$BASE/tuples" >/dev/null
h1=$(http_code "$BASE/tuples/gone1")
h2=$(http_code "$BASE/tuples/gone2")
if [[ "$h1" == "404" && "$h2" == "404" ]]; then Pass; else Fail; fi

# === Test H10: Invalid TTL returns 400 ===
Test "POST with invalid TTL returns 400"
code=$(http_code -X POST "$BASE/tuples/badttl?ttl=notanumber" -d "x")
CompareArgs "$code" "400"

# === Test H11: Invalid mode returns 400 ===
Test "POST with invalid mode returns 400"
code=$(http_code -X POST "$BASE/tuples/badmode?mode=invalid" -d "x")
CompareArgs "$code" "400"

# === Test H12: Invalid timeout on GET returns 400 ===
Test "GET with invalid timeout returns 400"
curl -sf -X POST "$BASE/tuples/timeouttest" -d "x" >/dev/null
code=$(http_code "$BASE/tuples/timeouttest?timeout=bad")
CompareArgs "$code" "400"

# === Test H13: CORS headers present ===
Test "Responses include CORS Access-Control-Allow-Origin header"
headers=$(curl -sI "$BASE/health")
if echo "$headers" | grep -qi "Access-Control-Allow-Origin"; then Pass; else Fail; fi

# === Test H14: OPTIONS preflight returns 200 ===
Test "OPTIONS preflight returns 200"
code=$(http_code -X OPTIONS "$BASE/tuples/anything")
CompareArgs "$code" "200"

# === Test H15: Unknown route returns 404 ===
Test "Unknown path returns 404"
code=$(http_code "$BASE/no/such/path")
CompareArgs "$code" "404"

# === Test H16: GET /api returns HTML ===
Test "GET /api returns HTML documentation"
content_type=$(curl -sI "$BASE/api" | grep -i "content-type")
if echo "$content_type" | grep -qi "text/html"; then Pass; else Fail; fi

# === Test H17: GET / redirects ===
Test "GET / redirects to /api"
code=$(http_code "$BASE/")
if [[ "$code" == 3* ]]; then Pass; else Fail; fi

# === Test H18: GET /tuples with pattern filters results ===
Test "GET /tuples?pattern= filters by pattern"
curl -sf -X DELETE "$BASE/tuples" >/dev/null
curl -sf -X POST "$BASE/tuples/apple" -d "a" >/dev/null
curl -sf -X POST "$BASE/tuples/apricot" -d "b" >/dev/null
curl -sf -X POST "$BASE/tuples/banana" -d "c" >/dev/null
resp=$(curl -sf "$BASE/tuples?pattern=ap*")
if echo "$resp" | grep -q 'apple' && echo "$resp" | grep -q 'apricot' && ! echo "$resp" | grep -q 'banana'; then
    Pass
else
    Fail
fi

# === Test H19: Response JSON is valid when data contains special characters ===
Test "Tuple data with double-quotes produces valid JSON response"
curl -sf -X POST "$BASE/tuples/quoted" --data-raw 'say "hello"' >/dev/null
resp=$(curl -sf "$BASE/tuples/quoted")
if echo "$resp" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    Pass
else
    Fail
fi

TestDone
