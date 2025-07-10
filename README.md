# Linda Tuple Space Implementations

This repository contains minimal file-based implementations of the Linda tuple space concept in three languages:

- Python: linda.py — data-agnostic API for storing and retrieving opaque bytes or strings as tuples
- Shell script: linda.sh — CLI tool using atomic file operations and native locking
- Tcl: linda.tcl — Tcl package providing similar API commands for tuple space access

---

Common Concepts

- Tuples are stored as files in a directory (LINDA_DIR environment variable, default /tmp/linda)
- Filenames encode tuple name, expiration timestamp (TTL), and a random suffix for uniqueness
- Expired tuples are automatically cleaned up on each operation
- Locking is done via atomic hardlink creation of .lock files to prevent concurrent access issues
- Tuple contents are opaque bytes or text — no serialization or specific data format is enforced

---

Python API (linda.py)

Functions:
- linda.out(name: str, data: bytes | str, ttl: int = 0)
- linda.inp(name_pattern: str, timeout: int | None = None) -> bytes
- linda.rd(name_pattern: str) -> bytes
- linda.ls(name_pattern: str) -> list[str]
- linda.once = -1  (Use as timeout to perform a non-blocking in)

Usage example:

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

---

Shell CLI (linda.sh)

Commands:

- echo "$DATA" | linda.sh out name [ttl_seconds]
- linda.sh inp name-or-pattern [once|timeout]
- linda.sh rd name-or-pattern
- linda.sh ls [name-or-pattern]

Description:
- out: write tuple with optional TTL in seconds
- in: blocking read-and-remove; optional second arg once (non-blocking) or timeout in seconds
- rd: blocking read without removing
- ls: list unexpired tuples matching pattern

---

Tcl Package (linda.tcl)

Commands:

- linda::out name data ?ttl?
- linda::inp namePattern ?timeout?
- linda::rd namePattern
- linda::ls ?namePattern?

Description:
- out: write tuple data (string), optional TTL seconds
- inp: blocking read-and-remove, optional timeout in seconds or once keyword for non-blocking
- rd: blocking read without removal
- ls: list matching tuples

---

Notes

- All implementations use atomic filesystem operations for concurrency control (hardlink-based locks).
- Expired tuples are cleaned automatically on each API invocation.
- Tuple data is treated as opaque content; no serialization enforced
