# Python Module — `linda.py`

A Python 3 module exposing Linda tuple-space operations. All read operations return `bytes`.

## Importing

```python
import linda
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `LINDA_DIR` | `/tmp/linda` | Directory where tuple files are stored |

## Constants

| Name | Value | Meaning |
|------|-------|---------|
| `linda.once` | sentinel | Pass as `timeout` for non-blocking operation |
| `linda.TUPLEDIR` | `Path` | Resolved path to the tuple directory |

## Exceptions

| Exception | Raised when |
|-----------|-------------|
| `linda.TupleNotFound` | No matching tuple and `timeout=linda.once` |
| `TimeoutError` | No matching tuple within the given timeout |
| `ValueError` | Invalid argument to `out` (bad TTL, conflicting modes) |

## Functions

### `linda.out(name, data, ttl=0, *, mode=None)`

Write a tuple.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `str` | Tuple name |
| `data` | `str \| bytes` | Data to store (strings are UTF-8 encoded) |
| `ttl` | `int` | Seconds until expiry (`0` = no expiry) |
| `mode` | `"seq" \| "rep" \| None` | `"seq"` = FIFO ordering; `"rep"` = replacement semantics |

Positional TTL is also accepted: `linda.out("name", data, 30)`.

### `linda.inp(pattern, timeout=None)`

Consume a tuple (read + remove). Returns `bytes`.

| `timeout` value | Behaviour |
|-----------------|-----------|
| `None` *(default)* | Block indefinitely |
| `linda.once` | Non-blocking: raise `TupleNotFound` if none |
| `int >= 0` | Block for at most that many seconds, then raise `TimeoutError` |

### `linda.rd(pattern, timeout=None)`

Read a tuple without removing it. Returns `bytes`. Same timeout semantics as `inp`.

### `linda.ls(pattern="*")`

Return a list of `"<count> <name>"` strings for all matching, non-expired tuples.

### `linda.clear()`

Delete all tuples and sequence files from `LINDA_DIR`.

## Examples

```python
import linda

# Basic produce / consume
linda.out("jobs", b"resize img.png", 30)
data = linda.inp("jobs")                    # blocks indefinitely
print(data.decode())

# Non-blocking
try:
    data = linda.inp("jobs", linda.once)
except linda.TupleNotFound:
    print("Nothing available")

# Timed wait
try:
    data = linda.inp("jobs", 5)
except TimeoutError:
    print("Timed out after 5 seconds")

# FIFO queue
for item in ["first", "second", "third"]:
    linda.out("queue", item, mode="seq")

print(linda.inp("queue", linda.once).decode())  # → first
print(linda.inp("queue", linda.once).decode())  # → second

# Replacement (shared config slot)
linda.out("config", "v1", mode="rep")
linda.out("config", "v2", mode="rep")
print(linda.rd("config", linda.once).decode())  # → v2

# Pattern matching
linda.out("job1", "a")
linda.out("job2", "b")
data = linda.rd("job*", linda.once)             # matches either

# List with counts
for entry in linda.ls():
    count, name = entry.split()
    print(f"{name}: {count} tuple(s)")

# Cleanup
linda.clear()
```
