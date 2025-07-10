import linda

# Publish a tuple lasting 10 seconds
linda.out("task", {"cmd": "cleanup"}, ttl=10)

# Blocking consume (wait forever)
data = linda.in_("task")

# Non-blocking consume (raises FileNotFoundError if none)
try:
    data = linda.in_("task", timeout=linda.once)
except FileNotFoundError:
    print("No tuple available")

# Timed consume (wait max 5 seconds)
try:
    data = linda.in_("task", timeout=5)
except TimeoutError:
    print("Timeout waiting for tuple")

# Peek without removing (blocks)
data = linda.rd("task")

# List tuples
print(linda.ls("task"))
