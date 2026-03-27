# Shell CLI — `linda.sh`

A Bash script that exposes the Linda tuple space as a command-line tool. Data is piped in on stdin (for `out`) and printed to stdout (for `inp`/`rd`).

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `LINDA_DIR` | `/tmp/linda` | Directory where tuple files are stored |

## Commands

### `out` — write a tuple

```
echo "data" | ./linda.sh out <name> [<ttl>] [seq] [rep]
```

Reads data from stdin and writes it as a named tuple.

| Argument | Description |
|----------|-------------|
| `name` | Tuple name (used as filename prefix) |
| `ttl` | Time-to-live in seconds (omit or `0` = no expiry) |
| `seq` | FIFO mode: prepend a sequence number so tuples are consumed in order |
| `rep` | Replacement mode: write without a random suffix so the next `rep` write atomically replaces this one |

`seq` and `rep` may be combined: the tuple gets a sequence number but no random suffix.

### `inp` — consume a tuple (blocking read + remove)

```
./linda.sh inp <pattern> [once | <timeout>]
```

Reads and removes the first matching tuple, printing its contents to stdout.

| Argument | Description |
|----------|-------------|
| `pattern` | Glob pattern matched against tuple names (e.g. `job*`) |
| *(omitted)* | Block indefinitely until a match appears |
| `once` | Non-blocking: exit with status 1 immediately if no match |
| `timeout` | Block for at most this many seconds, then exit with status 1 |

### `rd` — read a tuple without consuming

```
./linda.sh rd <pattern> [once | <timeout>]
```

Same as `inp` but leaves the tuple in place.

### `ls` — list tuples

```
./linda.sh ls [pattern]
```

Prints one line per tuple name with a count: `<count> <name>`. Expired tuples are excluded. Omit `pattern` to list all.

### `clear` — remove all tuples

```
./linda.sh clear
```

Deletes every tuple file and sequence file from `LINDA_DIR`.

## Examples

```bash
# Publish a task with a 30-second TTL
echo '{"task":"resize","file":"img.png"}' | ./linda.sh out jobs 30

# Worker: consume tasks one at a time (blocks between tasks)
while true; do
    data=$(./linda.sh inp jobs)
    echo "Processing: $data"
done

# FIFO queue: produces items in order
for i in 1 2 3; do
    echo "item $i" | ./linda.sh out queue seq
done
./linda.sh inp queue   # → item 1
./linda.sh inp queue   # → item 2

# Shared config slot (replacement semantics)
echo "v1" | ./linda.sh out config rep
echo "v2" | ./linda.sh out config rep
./linda.sh rd config   # → v2

# Non-blocking try
if result=$(./linda.sh inp jobs once 2>/dev/null); then
    echo "Got: $result"
else
    echo "Nothing available"
fi

# Timed wait
./linda.sh inp jobs 5 || echo "Timed out"
```
