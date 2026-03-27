# Tcl Package — `linda.tcl`

A Tcl namespace ensemble exposing Linda tuple-space operations. Strings are stored and returned as Tcl strings (UTF-8 safe).

## Loading

```tcl
source linda.tcl
package require linda
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `LINDA_DIR` | `/tmp/linda` | Directory where tuple files are stored |

## Commands

All commands are in the `linda` namespace and available as a namespace ensemble (so `linda out …` or `linda::out …` both work).

### `linda out` — write a tuple

```
linda out <name> <data> ?<ttl>? ?seq? ?rep?
```

| Argument | Description |
|----------|-------------|
| `name` | Tuple name |
| `data` | Data string |
| `ttl` | Seconds until expiry (`0` = no expiry, default `0`) |
| `seq` | FIFO mode: prepend a sequence number |
| `rep` | Replacement mode: no random suffix (next `rep` write atomically replaces) |

Arguments may appear in any order after `data`. Raises an error for invalid arguments.

### `linda inp` — consume a tuple (blocking read + remove)

```
linda inp <pattern> ?<timeout>?
```

Returns the data of the first matching tuple and removes it.

| Second arg | Behaviour |
|------------|-----------|
| *(omitted)* | Block indefinitely |
| `once` | Non-blocking: raise `"No tuple matching …"` immediately if none |
| integer ≥ 0 | Block for at most that many seconds, then raise `"Timeout …"` |

### `linda rd` — read without consuming

```
linda rd <pattern> ?<timeout>?
```

Same as `inp` but leaves the tuple in place. Same timeout semantics.

### `linda ls` — list tuples

```
linda ls ?<pattern>?
```

Returns a list of strings of the form `"<count> <name>"`. Omit `pattern` to list all.

### `linda clear` — remove all tuples

```
linda clear
```

Deletes every tuple and sequence file from `LINDA_DIR`.

## Examples

```tcl
source linda.tcl
package require linda

# Basic produce / consume
linda out jobs "resize img.png" 30
set task [linda inp jobs]

# Non-blocking
if {[catch {linda inp jobs once} task]} {
    puts "Nothing available"
} else {
    puts "Got: $task"
}

# Timed wait
if {[catch {linda inp jobs 5} task]} {
    puts "Timed out"
} else {
    puts "Got: $task"
}

# FIFO queue
linda out queue "first"  seq
linda out queue "second" seq
linda out queue "third"  seq
puts [linda inp queue once]  ;# → first
puts [linda inp queue once]  ;# → second

# Replacement (shared config slot)
linda out config "v1" rep
linda out config "v2" rep
puts [linda rd config once]  ;# → v2

# Pattern matching
linda out job1 "a"
linda out job2 "b"
puts [linda rd job* once]    ;# → a or b

# List
foreach entry [linda ls] {
    lassign $entry count name
    puts "$name: $count tuple(s)"
}
```
