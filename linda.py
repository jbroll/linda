import os
import time
import tempfile
import glob
import random
import string

TUPLEDIR = os.environ.get("LINDA_DIR", "/tmp/linda")
os.makedirs(TUPLEDIR, exist_ok=True)


def _lock_file(filepath):
    lockfile = filepath + ".lock"
    try:
        os.link(filepath, lockfile)
        return lockfile
    except FileExistsError:
        return None


def _unlock_file(lockfile):
    try:
        os.unlink(lockfile)
    except FileNotFoundError:
        pass


def _expire_tuples():
    now = int(time.time())
    for path in glob.glob(os.path.join(TUPLEDIR, "*")):
        parts = os.path.basename(path).split(".")
        if len(parts) < 3:
            continue
        try:
            expiry = int(parts[-2])
        except ValueError:
            continue
        if expiry != 0 and now >= expiry:
            lockfile = path + ".lock"
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            try:
                os.unlink(lockfile)
            except FileNotFoundError:
                pass


def _is_expired(path):
    parts = os.path.basename(path).split(".")
    if len(parts) < 3:
        return True
    try:
        expiry = int(parts[-2])
    except ValueError:
        return True
    if expiry == 0:
        return False
    return int(time.time()) >= expiry


def _find_and_lock(pattern):
    for path in glob.glob(os.path.join(TUPLEDIR, f"{pattern}*")):
        if _is_expired(path):
            continue
        lockfile = _lock_file(path)
        if lockfile:
            return path, lockfile
    return None, None


def out(name, data, ttl=0):
    """
    Write a tuple named 'name' with opaque data (bytes or str) and optional TTL in seconds.
    """
    _expire_tuples()

    expiry = int(time.time()) + ttl if ttl > 0 else 0
    rand = ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))
    filename = f"{name}.{expiry}.{rand}"
    path = os.path.join(TUPLEDIR, filename)

    # Write atomically via tempfile
    fd, tmp_path = tempfile.mkstemp(prefix=f"tmp.{name}.", dir=TUPLEDIR)
    with os.fdopen(fd, "wb") as f:
        if isinstance(data, str):
            data = data.encode("utf-8")
        f.write(data)
    os.rename(tmp_path, path)


def inp(name_pattern, timeout=None):
    """
    Blocking or non-blocking input (read and remove).
    timeout=None or 0 = block forever
    timeout > 0 = block up to timeout seconds
    timeout = -1 = non-blocking (once)
    Returns bytes.
    """
    _expire_tuples()

    start = time.time()
    while True:
        path, lockfile = _find_and_lock(name_pattern)
        if path:
            try:
                with open(path, "rb") as f:
                    data = f.read()
            finally:
                os.unlink(path)
                _unlock_file(lockfile)
            return data

        if timeout == -1:
            raise FileNotFoundError(f"No tuple matching '{name_pattern}'")

        if timeout and timeout > 0:
            elapsed = time.time() - start
            if elapsed >= timeout:
                raise TimeoutError(f"Timeout waiting for tuple '{name_pattern}'")

        time.sleep(0.1)


def rd(name_pattern):
    """
    Blocking read (peek) without removing.
    Returns bytes.
    """
    _expire_tuples()
    while True:
        path, lockfile = _find_and_lock(name_pattern)
        if path:
            try:
                with open(path, "rb") as f:
                    data = f.read()
            finally:
                _unlock_file(lockfile)
            return data
        time.sleep(0.1)


def ls(pattern):
    _expire_tuples()
    matches = []
    for path in glob.glob(os.path.join(TUPLEDIR, f"{pattern}*")):
        if not _is_expired(path):
            matches.append(os.path.basename(path))
    return matches


once = -1
