# Publish tuple lasting 30s
echo '{"task":"cleanup"}' | ./linda.sh out cleanup 30

# Blocking read and remove (waits indefinitely)
./linda.sh in cleanup

# Non-blocking read and remove (fails immediately if none)
./linda.sh in cleanup once

# Read and remove with 10s timeout
./linda.sh in cleanup 10

# Peek at a tuple (no remove)
./linda.sh rd cleanup

# List tuples
./linda.sh ls
./linda.sh ls cleanup
