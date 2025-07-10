# Linda Tuple Space Implementations

This repository contains minimal file-based implementations of the Linda tuple space concept in three languages:

- **Python**: `linda.py` — data-agnostic API for storing and retrieving opaque bytes or strings as tuples
- **Shell script**: `linda.sh` — CLI tool using atomic file operations and native locking
- **Tcl**: `linda.tcl` — Tcl package providing similar API commands for tuple space access

## Common Concepts

- Tuples are stored as files in a directory (`LINDA_DIR` environment variable, default `/tmp/linda`)
- Filenames encode tuple name, expiration timestamp (TTL), and a random suffix for uniqueness
- Expired tuples are automatically cleaned up on each operation
- Locking is done via atomic file creation with PID checking and timeout handling
- Tuple contents are opaque bytes or text — no serialization or specific data format is enforced

## Lock-Free Design (Tcl Implementation)

The Tcl implementation uses a mostly lock-free design for maximum performance and concurrency:

### Lock-Free Operations

- **Reads (`inp`/`rd`)**: Use atomic filesystem operations. If a file is removed between `glob` and `open`, the operation retries with a fresh directory listing. Once a file handle is obtained, the file contents remain stable even if another process removes the file.

- **Writes (`out`)**: Use atomic write-then-rename semantics. Each write creates a unique temporary file, writes the data, then atomically renames it to the final filename.

- **Tuple consumption (`inp`)**: After reading a tuple, attempts to remove the file. If removal fails (another process consumed it), that's acceptable since we already have the data.

### Locking Used Only For

- **Sequence number generation**: The `seq` flag requires coordinated sequence numbering, so file-based locking is used only for the sequence file.

### Replacement Semantics Limitation

**IMPORTANT**: Mixing `out name data` (normal) and `out name data rep` (replacement) for the same tuple name results in **undefined behavior**.

- Normal `out` creates files like `name-XXXXXXXX` (with random suffix)
- Replacement `out rep` creates files like `name` (no suffix)
- A `rd` or `inp` operation might return data from either file type

**Recommendation**: Use replacement semantics (`rep`) only for singleton tuples where you want exactly one value to exist. Do not mix `rep` with other `out` operations on the same tuple name.

This design choice preserves the performance benefits of lock-free operation while acknowledging the semantic limitation.

## Python API (linda.py)

### Functions

- `linda.out(name: str, data: bytes | str, ttl: int = 0)`
- `linda.inp(name_pattern: str, timeout: int | None = None) -> bytes`
- `linda.rd(name_pattern: str) -> bytes`
- `linda.ls(name_pattern: str) -> list[str]`
- `linda.once = -1` (Use as timeout to perform a non-blocking in)

### Usage Example

```python
import linda

linda.out("job", b"payload", ttl=30)

data = linda.in_("job")  # blocks indefinitely
data = linda.in_("job", timeout=5)  # blocks up to 5 seconds

try:
    data = linda.in_("job", timeout=linda.once)  # non-blocking
except FileNotFoundError:
    print("No tuple available")

peek = linda.rd("job")
print(linda.ls("job*"))
```

## Shell CLI (linda.sh)

### Commands

```bash
echo "$DATA" | linda.sh out name [ttl_seconds|seq|rep]
linda.sh inp name-or-pattern [once|timeout_seconds]
linda.sh rd name-or-pattern [once]
linda.sh ls [name-or-pattern]
linda.sh clear
```

### Command Descriptions

- **out**: Write tuple with optional TTL in seconds. Additional options:
  - `seq`: Adds sequence number for FIFO ordering
  - `rep`: Omits random suffix for replacement semantics
- **inp**: Blocking read-and-remove; optional second arg `once` (non-blocking) or timeout in seconds
- **rd**: Blocking read without removing; optional `once` arg for non-blocking
- **ls**: List unexpired tuples with counts by name
- **clear**: Remove all tuples from the tuple space

### File Naming Convention

- **Standard**: `name-XXXXXXXX.expires` (name + random hex + optional expiry)
- **With sequence**: `name-NNNNNNNN-XXXXXXXX.expires` (name + sequence + random hex + optional expiry)
- **Replaceable**: `name.expires` (name + optional expiry, no random suffix)

## Tcl Package (linda.tcl)

### Commands

- `linda out name data ?ttl?`
- `linda inp namePattern ?timeout?`
- `linda rd namePattern ?timeout?`
- `linda ls ?namePattern?`

### Command Descriptions

- **out**: Write tuple data (string), optional TTL seconds
- **inp**: Blocking read-and-remove, optional timeout in seconds or `once` keyword for non-blocking
- **rd**: Blocking read without removal, optional timeout in seconds or `once` keyword for non-blocking  
- **ls**: List matching tuples

## Implementation Notes

- All implementations use atomic filesystem operations for concurrency control
- Shell implementation uses PID-based locking with stale lock detection and 5-second timeout
- Expired tuples are cleaned automatically on each API invocation
- Tuple data is treated as opaque content; no serialization enforced
- Shell implementation supports sequence numbering for FIFO semantics and replacement semantics
- Tcl implementation uses mostly lock-free design with documented limitations for mixed operation types