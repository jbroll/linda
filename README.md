# Linda Tuple Space

A minimal, file-based implementation of [Linda](https://en.wikipedia.org/wiki/Linda_(coordination_language)) tuple-space coordination primitives — available in Shell, Tcl, and Python, with an optional HTTP REST API.

## What is a tuple space?

A tuple space is a shared, persistent blackboard for inter-process communication. Processes write named data items (*tuples*) into the space and other processes read or consume them. Readers block until a matching tuple appears, making it a natural fit for task queues, worker pools, and pipeline coordination.

The three core operations are:

| Operation | Meaning |
|-----------|---------|
| `out name data` | Write a tuple |
| `rd  name`      | Read a tuple (non-destructive, blocks until present) |
| `inp name`      | Consume a tuple (read + remove, blocks until present) |

## How it works

Tuples are plain files in a directory (`LINDA_DIR`, default `/tmp/linda`). The filename encodes the tuple name, an optional sequence number (FIFO ordering), an optional random suffix (uniqueness), and an optional expiry timestamp (TTL). Writes are atomic (temp-file + rename). Reads are lock-free. Consumes use a per-file PID lock with stale-lock recovery.

Because storage is the filesystem, any number of processes in any language can share the same tuple space simultaneously.

## Implementations

| File | Language | Usage |
|------|----------|-------|
| `linda.sh`  | Bash | CLI — pipe data in/out |
| `linda.tcl` | Tcl  | `package require linda` (namespace ensemble) |
| `linda.py`  | Python 3 | `import linda` |
| `linda-http.tcl` | Tcl + wapp | HTTP REST API |

See the per-implementation reference docs:

- [Shell CLI](doc/shell.md)
- [Tcl package](doc/tcl.md)
- [Python module](doc/python.md)
- [HTTP API](doc/http.md)

## Quick examples

**Shell**
```bash
echo "payload" | ./linda.sh out jobs
./linda.sh inp jobs          # blocks until a tuple appears, then prints it
./linda.sh rd  jobs once     # non-blocking peek
```

**Tcl**
```tcl
source linda.tcl
linda out jobs "payload"
set data [linda inp jobs]        ;# blocks
set data [linda inp jobs once]   ;# non-blocking
```

**Python**
```python
import linda
linda.out("jobs", b"payload")
data = linda.inp("jobs")           # blocks
data = linda.inp("jobs", linda.once)  # non-blocking (raises TupleNotFound)
```

**HTTP**
```bash
curl -X POST http://localhost:8080/tuples/jobs -d "payload"
curl          http://localhost:8080/tuples/jobs        # rd
curl -X DELETE http://localhost:8080/tuples/jobs       # inp
```

## Features

- **TTL** — tuples expire automatically after N seconds
- **FIFO** (`seq` mode) — sequence-numbered tuples are consumed in order
- **Replacement** (`rep` mode) — at most one tuple per name; second write overwrites the first
- **Pattern matching** — `rd`/`inp`/`ls` accept glob patterns (`job*`)
- **Blocking / timeout / non-blocking** — all read operations support all three modes
- **Cross-language** — Shell, Tcl, and Python share the same file format and locking protocol

## Running the tests

```bash
make test          # all suites
make test-sh       # Shell (17 tests)
make test-tcl      # Tcl   (26 tests)
make test-py       # Python (35 tests)
./test-linda-http.sh   # HTTP (19 tests, requires wapp.tcl)
```
