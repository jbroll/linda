import linda
import time

# Clear any existing tuples
linda.clear()

print("=== Basic Linda Operations ===")

# Publish a tuple lasting 10 seconds
linda.out("task", b"cleanup job", 10)
print("Published task with 10s TTL")

# Blocking consume (wait forever)
print("Consuming task...")
data = linda.inp("task")
print(f"Got: {data}")

# Non-blocking consume (raises TupleNotFound if none)
try:
    data = linda.inp("task", timeout=linda.once)
    print(f"Got: {data}")
except linda.TupleNotFound:
    print("No tuple available (expected)")

# Timed consume (wait max 2 seconds)
print("Trying to consume with 2s timeout...")
try:
    data = linda.inp("task", timeout=2)
    print(f"Got: {data}")
except TimeoutError:
    print("Timeout waiting for tuple (expected)")

print("\n=== Advanced Features ===")

# Sequence numbering for FIFO semantics
print("Testing FIFO with sequence numbering:")
linda.out("fifo", "first", mode="seq")
linda.out("fifo", "second", mode="seq") 
linda.out("fifo", "third", mode="seq")

# Should come out in FIFO order
print(f"1: {linda.inp('fifo', linda.once).decode()}")
print(f"2: {linda.inp('fifo', linda.once).decode()}")
print(f"3: {linda.inp('fifo', linda.once).decode()}")

# Replacement semantics
print("\nTesting replacement semantics:")
linda.out("config", "old value", mode="rep")
linda.out("config", "new value", mode="rep")
# Should only have one tuple
print(f"Config: {linda.inp('config', linda.once).decode()}")

# Multiple tuples with same name
print("\nTesting multiple tuples:")
linda.out("multi", "data1")
linda.out("multi", "data2")
linda.out("multi", "data3")

# Read without consuming
peek = linda.rd("multi", linda.once)
print(f"Peeked at: {peek.decode()}")

# List tuples with counts
print(f"Listing: {linda.ls('multi')}")

# Consume all
while True:
    try:
        data = linda.inp("multi", linda.once)
        print(f"Consumed: {data.decode()}")
    except linda.TupleNotFound:
        break

print("\n=== Pattern Matching ===")

# Create tuples with different prefixes
linda.out("test1", "data1")
linda.out("test2", "data2") 
linda.out("other", "data3")

# Pattern matching
try:
    data = linda.rd("test*", linda.once)
    print(f"Found test*: {data.decode()}")
except linda.TupleNotFound:
    print("No match for test*")

# List with pattern
print(f"All tuples: {linda.ls()}")
print(f"Test tuples: {linda.ls('test*')}")

print("\n=== TTL and Expiry ===")

# Short-lived tuple
linda.out("temp", "expires soon", 2)
print("Created tuple with 2s TTL")
print(f"Reading immediately: {linda.rd('temp', linda.once).decode()}")

print("Waiting 3 seconds...")
time.sleep(3)

try:
    data = linda.rd("temp", linda.once)
    print(f"Still there: {data.decode()}")
except linda.TupleNotFound:
    print("Tuple expired (expected)")

# Final cleanup
linda.clear()
print("\nCleared all tuples")