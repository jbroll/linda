# HTTP API — `linda-http.tcl`

A REST API wrapper around the Tcl Linda implementation, built with the [wapp](https://wapp.tcl.tk/) web framework.

## Setup

Requires `wapp.tcl` and `wapp-routes.tcl` in the working directory (or symlinked there).

```bash
tclsh linda-http.tcl                  # listens on 127.0.0.1:8080
tclsh linda-http.tcl -local 9090      # custom port (loopback only)
tclsh linda-http.tcl -server 0.0.0.0:8080  # all interfaces
```

The `LINDA_DIR` environment variable controls the tuple directory (default `/tmp/linda`).

## Endpoints

All responses are JSON. All responses include CORS headers (`Access-Control-Allow-Origin: *`).

---

### `GET /health`

Returns server status.

```json
{"status": "healthy", "service": "linda-http"}
```

---

### `POST /tuples/{name}`

Write a tuple (`out`). Body is the raw tuple data.

**Query parameters:**

| Parameter | Description |
|-----------|-------------|
| `ttl=N` | Seconds until expiry (default: no expiry) |
| `mode=seq` | FIFO ordering |
| `mode=rep` | Replacement semantics |

**Response `200`:**
```json
{"success": true, "message": "Tuple stored", "name": "jobs"}
```

**Response `400`** — invalid `ttl` or `mode`.

---

### `GET /tuples/{name}`

Read a tuple without consuming it (`rd`).

**Query parameters:**

| Parameter | Description |
|-----------|-------------|
| `timeout=once` | Non-blocking (default) |
| `timeout=N` | Block for at most N seconds |

**Response `200`:**
```json
{"success": true, "name": "jobs", "data": "resize img.png"}
```

**Response `404`** — no matching tuple.
**Response `408`** — timeout elapsed.
**Response `400`** — invalid `timeout`.

---

### `DELETE /tuples/{name}`

Consume a tuple (`inp`). Same `timeout` parameter as GET.

**Response `200`:**
```json
{"success": true, "name": "jobs", "data": "resize img.png"}
```

**Response `404`** — no matching tuple.

---

### `GET /tuples`

List tuples (`ls`).

**Query parameters:**

| Parameter | Description |
|-----------|-------------|
| `pattern=*` | Glob filter (default: all) |

**Response `200`:**
```json
{"success": true, "tuples": [{"name": "jobs", "count": 3}]}
```

---

### `DELETE /tuples`

Clear all tuples (`clear`).

**Response `200`:**
```json
{"success": true, "message": "All tuples cleared"}
```

---

### `GET /api`

Returns HTML documentation for the API.

### `OPTIONS *`

Returns `200` with CORS preflight headers.

---

## Examples

```bash
# Store a task with 60s TTL
curl -X POST "http://localhost:8080/tuples/jobs?ttl=60" -d "resize img.png"

# Store in FIFO queue
curl -X POST "http://localhost:8080/tuples/queue?mode=seq" -d "first"
curl -X POST "http://localhost:8080/tuples/queue?mode=seq" -d "second"

# Read without consuming (non-blocking)
curl "http://localhost:8080/tuples/jobs"

# Consume (non-blocking)
curl -X DELETE "http://localhost:8080/tuples/jobs"

# Consume with 5-second wait
curl -X DELETE "http://localhost:8080/tuples/jobs?timeout=5"

# List all tuples
curl "http://localhost:8080/tuples"

# List matching a pattern
curl "http://localhost:8080/tuples?pattern=job*"

# Clear everything
curl -X DELETE "http://localhost:8080/tuples"
```

## Notes

- The HTTP server is single-threaded. Avoid long `timeout` values on GET/DELETE — they block the server from handling other requests. Use `timeout=once` (the default) for interactive clients and handle retries client-side.
- Tuple data is returned as a JSON string. Binary data is supported but will be escaped.
