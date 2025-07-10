import os
import time
import tempfile
import glob
import random
import string
import contextlib
from pathlib import Path
from typing import Union, Optional, List, Iterator

TUPLEDIR = Path(os.environ.get("LINDA_DIR", "/tmp/linda"))
TUPLEDIR.mkdir(parents=True, exist_ok=True)

# Constants
once = -1  # Fixed typo from original
LOCK_TIMEOUT = 5.0  # seconds


class TupleNotFound(Exception):
    """Raised when a tuple is not found in non-blocking operations."""
    pass


class LockTimeout(Exception):
    """Raised when lock acquisition times out."""
    pass


def _random_suffix(length: int = 8) -> str:
    """Generate random hex suffix for tuple filenames."""
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))


def _parse_filename(filename: str) -> tuple[str, int, str]:
    """Parse tuple filename into (name, expiry, suffix)."""
    parts = filename.split('.')
    if len(parts) < 3:
        raise ValueError(f"Invalid tuple filename: {filename}")
    
    name = parts[0]
    try:
        expiry = int(parts[1])
    except ValueError:
        raise ValueError(f"Invalid expiry in filename: {filename}")
    
    suffix = '.'.join(parts[2:])
    return name, expiry, suffix


def _is_expired(filepath: Path) -> bool:
    """Check if a tuple file has expired."""
    try:
        _, expiry, _ = _parse_filename(filepath.name)
        return expiry != 0 and time.time() >= expiry
    except ValueError:
        return True


@contextlib.contextmanager
def _file_lock(filepath: Path, timeout: float = LOCK_TIMEOUT) -> Iterator[Path]:
    """Context manager for file locking using link-based atomic operations."""
    lockfile = filepath.with_suffix(filepath.suffix + '.lock')
    start_time = time.time()
    
    while True:
        try:
            # Atomic lock creation using hard link
            os.link(str(filepath), str(lockfile))
            break
        except FileExistsError:
            # Check for stale locks and timeout
            if time.time() - start_time > timeout:
                raise LockTimeout(f"Failed to acquire lock for {filepath}")
            time.sleep(0.05)
        except FileNotFoundError:
            # Original file was deleted, can't lock
            raise TupleNotFound(f"Tuple file {filepath} not found")
    
    try:
        yield lockfile
    finally:
        lockfile.unlink(missing_ok=True)


def _cleanup_expired() -> None:
    """Remove all expired tuple files."""
    current_time = time.time()
    
    for filepath in TUPLEDIR.glob("*.*"):
        if _is_expired(filepath):
            try:
                filepath.unlink()
                # Also remove any stale lock files
                lockfile = filepath.with_suffix(filepath.suffix + '.lock')
                lockfile.unlink(missing_ok=True)
            except FileNotFoundError:
                pass


def _find_matching_tuples(pattern: str) -> List[Path]:
    """Find all non-expired tuples matching the pattern."""
    matches = []
    for filepath in TUPLEDIR.glob(f"{pattern}*"):
        if not _is_expired(filepath):
            matches.append(filepath)
    return sorted(matches)  # Consistent ordering


def out(name: str, data: Union[bytes, str], ttl: int = 0) -> None:
    """Write a tuple with optional TTL."""
    _cleanup_expired()
    
    if ttl < 0:
        raise ValueError("TTL must be non-negative")
    
    expiry = int(time.time()) + ttl if ttl > 0 else 0
    suffix = _random_suffix()
    filename = f"{name}.{expiry}.{suffix}"
    filepath = TUPLEDIR / filename
    
    # Convert string to bytes if needed
    if isinstance(data, str):
        data = data.encode('utf-8')
    
    # Atomic write using temporary file
    with tempfile.NamedTemporaryFile(
        mode='wb',
        dir=TUPLEDIR,
        prefix=f"tmp.{name}.",
        delete=False
    ) as tmp_file:
        tmp_file.write(data)
        tmp_path = Path(tmp_file.name)
    
    tmp_path.rename(filepath)


def inp(name_pattern: str, timeout: Optional[float] = None) -> bytes:
    """
    Input (read and remove) a tuple matching the pattern.
    
    Args:
        name_pattern: Pattern to match tuple names
        timeout: None = block forever, once = non-blocking, positive = timeout in seconds
    
    Returns:
        Tuple data as bytes
        
    Raises:
        TupleNotFound: If no matching tuple (non-blocking mode)
        TimeoutError: If timeout exceeded
    """
    _cleanup_expired()
    
    if timeout == once:
        # Non-blocking mode
        matches = _find_matching_tuples(name_pattern)
        if not matches:
            raise TupleNotFound(f"No tuple matching '{name_pattern}'")
        
        filepath = matches[0]
        try:
            with _file_lock(filepath):
                with open(filepath, 'rb') as f:
                    data = f.read()
                filepath.unlink()
                return data
        except (FileNotFoundError, TupleNotFound):
            raise TupleNotFound(f"No tuple matching '{name_pattern}'")
    
    # Blocking mode with optional timeout
    start_time = time.time()
    
    while True:
        matches = _find_matching_tuples(name_pattern)
        
        for filepath in matches:
            try:
                with _file_lock(filepath, timeout=0.1):  # Short lock timeout for retry
                    with open(filepath, 'rb') as f:
                        data = f.read()
                    filepath.unlink()
                    return data
            except (FileNotFoundError, TupleNotFound, LockTimeout):
                continue  # Try next match or retry
        
        # Check timeout
        if timeout is not None and timeout > 0:
            elapsed = time.time() - start_time
            if elapsed >= timeout:
                raise TimeoutError(f"Timeout waiting for tuple '{name_pattern}'")
        
        time.sleep(0.1)


def rd(name_pattern: str) -> bytes:
    """Read (peek) a tuple without removing it."""
    _cleanup_expired()
    
    while True:
        matches = _find_matching_tuples(name_pattern)
        
        for filepath in matches:
            try:
                with _file_lock(filepath, timeout=0.1):
                    with open(filepath, 'rb') as f:
                        return f.read()
            except (FileNotFoundError, TupleNotFound, LockTimeout):
                continue
        
        time.sleep(0.1)


def ls(pattern: str = "*") -> List[str]:
    """List all tuple names matching the pattern."""
    _cleanup_expired()
    
    names = []
    for filepath in TUPLEDIR.glob(f"{pattern}*"):
        if not _is_expired(filepath):
            try:
                name, _, _ = _parse_filename(filepath.name)
                names.append(name)
            except ValueError:
                continue
    
    return sorted(list(set(names)))  # Remove duplicates and sort


def clear() -> None:
    """Remove all tuples from the tuple space."""
    for filepath in TUPLEDIR.glob("*"):
        try:
            filepath.unlink()
        except FileNotFoundError:
            pass


# Backwards compatibility aliases
in_ = inp  # Avoid Python keyword conflict