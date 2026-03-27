# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See [README.md](README.md) for the user-facing overview and [doc/](doc/) for per-implementation reference docs.

## Commands

```bash
make test           # all suites (Shell, Tcl, Python)
make test-sh        # ./test-linda.sh      (17 tests)
make test-tcl       # tclsh test-linda.tcl (26 tests)
make test-py        # python3 test-linda.py (35 tests)
./test-linda-http.sh            # HTTP tests (19 tests, requires wapp.tcl symlink)
tclsh linda-http.tcl -local 8080  # start HTTP server
```

## Architecture

Tuples are files in `LINDA_DIR` (`/tmp/linda` by default). The filename encodes all metadata:

```
name-XXXXXXXX[.EXPIRY]          # normal (random hex suffix)
name-NNNNNNNN-XXXXXXXX[.EXPIRY] # FIFO (seq number + random hex)
name[.EXPIRY]                   # replacement (no suffix)
```

Expiry is a Unix timestamp appended as `.NNNNNNNNNN`. Only values ≥ 1,000,000,000 are treated as timestamps (prevents false positives for short numeric name suffixes).

**Concurrency:** writes are atomic (tmp + rename); `rd` is lock-free; `inp` acquires a per-file PID lock with stale-lock recovery. Locking uses `CREAT EXCL` (Tcl/Python) or `noclobber` + rename (Shell).

All three implementations (Shell, Tcl, Python) share the same file format and locking protocol and can operate on the same `LINDA_DIR` simultaneously.
