import os
import time
import tempfile
import glob
import random
import string
import contextlib
import fcntl
from pathlib import Path
from typing import Union, Optional, List, Iterator

TUPLEDIR = Path(os.environ.get("LINDA_DIR", "/tmp/linda"))
TUPLEDIR.mkdir(parents=True, exist_ok=True)

# Constants
once = -1  # Special timeout value for non-blocking operations
LOCK_TIMEOUT = 5.0  # seconds


class TupleNotFound(Exception):
    """Raised when a tuple is not found in non-blocking operations."""
    pass


class LockTimeout(Exception):
    """Raised when lock acquisition times out."""
    pass


def _random_suffix(length: int = 8) -> str:
    """Generate random hex suffix for tuple filenames."""
    return ''.join(random.choices('0123456789abcdef', k=length))


def _parse_filename(filename: str) -> tuple[str, int, str]:
    """Parse tuple filename into (name, expiry, suffix).
    
    Handles various filename formats:
    - name-XXXXXXXX.expires
    - name-NNNNNNNN-XXXXXXXX.expires (with sequence)
    - name.expires (replacement semantics)
    - name-XXXXXXXX (no expiry)
    - name (replacement, no expiry)
    """
    if '.' in filename:
        base, expires_str = filename.rsplit('.', 1)
        try:
            expiry = int(expires_str)
        except ValueError:
            # Not a valid expiry, treat as part of name
            base = filename
            expiry = 0
    else:
        base = filename
        expiry = 0
    
    # Extract the tuple name (everything before first hyphen, or the whole thing)
    if '-' in base:
        name = base.split('-')[0]
    else:
        name = base
    
    return name, expiry, base


def _is_expired(filepath: Path) -> bool:
    """Check if a tuple file has expired."""
    try:
        _, expiry, _ = _parse_filename(filepath.name)
        return expiry != 0 and time.time() >= expiry
    except ValueError:
        return True


@contextlib.contextmanager
def _file_lock(filepath: Path, timeout: float = LOCK_TIMEOUT) -> Iterator[None]:
    """Context manager for file locking using fcntl."""
    lockfile = filepath.with_suffix(filepath.suffix + '.lock')
    start_time = time.time()
    
    while True:
        try:
            # Create lock file and acquire exclusive lock
            fd = os.open(str(lockfile), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.write(fd, str(os.getpid()).encode())
            break
        except FileExistsError:
            # Check for stale locks and timeout
            if time.time() - start_time > timeout:
                raise LockTimeout(f"Failed to acquire lock for {filepath}")
            
            # Check if lock is stale
            try:
                with open(lockfile, 'r') as f:
                    pid = int(f.read().strip())
                # Check if process is still running
                try:
                    os.kill(pid, 0)
                except (OSError, ProcessLookupError):
                    # Process is dead, remove stale lock
                    lockfile.unlink(missing_ok=True)
                    continue
            except (FileNotFoundError, ValueError, OSError):
                # Corrupt or missing lock file
                lockfile.unlink(missing_ok=True)
                continue
                
            time.sleep(0.05)
        except FileNotFoundError:
            # Original file was deleted, can't lock
            raise TupleNotFound(f"Tuple file {filepath} not found")
    
    try:
        yield
    finally:
        os.close(fd)
        lockfile.unlink(missing_ok=True)


def _next_seq(name: str) -> str:
    """Generate next sequence number for FIFO semantics."""
    seqfile = TUPLEDIR / f".{name}.seq"
    
    try:
        with _file_lock(seqfile):
            seq = 0
            if seqfile.exists():
                try:
                    seq = int(seqfile.read_text().strip())
                except (ValueError, FileNotFoundError):
                    seq = 0
            
            seq += 1
            seqfile.write_text(f"{seq:08d}")
            return f"-{seq:08d}"
    except LockTimeout:
        raise LockTimeout(f"Failed to acquire sequence lock for {name}")


def _cleanup_expired() -> None:
    """Remove all expired tuple files."""
    current_time = time.time()
    
    for filepath in TUPLEDIR.glob("*"):
        if filepath.name.startswith('.'):
            continue  # Skip hidden files like sequence files
        
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
    
    # Handle glob patterns - if pattern contains *, use it directly
    if '*' in pattern or '?' in pattern:
        search_pattern = pattern
    else:
        # Exact name match - look for files starting with name
        search_pattern = f"{pattern}*"
    
    for filepath in TUPLEDIR.glob(search_pattern):
        if filepath.name.startswith('.'):
            continue  # Skip hidden files
        if not _is_expired(filepath):
            matches.append(filepath)
    
    return sorted(matches)  # Consistent ordering for FIFO with sequences


def out(name: str, data: Union[bytes, str], *args, ttl: int = 0, mode: Optional[str] = None) -> None:
    """Write a tuple with optional TTL and mode (sequence or replacement semantics).
    
    Supports multiple calling styles:
    1. out(name, data) - basic
    2. out(name, data, ttl=30, mode="seq") - keyword args
    3. out(name, data, 30, "seq") - shell script style
    
    Args:
        name: Tuple name
        data: Tuple data (string or bytes)
        *args: Variable arguments (TTL int, mode string)
        ttl: Time to live in seconds (keyword only)
        mode: Storage mode (keyword only)
        
    Mode options:
        None (default): Normal tuple with random suffix
        "seq": FIFO semantics with sequence numbering
        "rep": Replacement semantics (no random suffix, overwrites)
    """
    _cleanup_expired()
    
    # Parse variable args (shell script style) - these override keyword args
    parsed_ttl = ttl
    parsed_mode = mode
    
    for arg in args:
        if isinstance(arg, int) and arg >= 0:
            parsed_ttl = arg
        elif arg in ("seq", "rep"):
            if parsed_mode is not None:
                raise ValueError(f"Mode already set to '{parsed_mode}', cannot also set '{arg}'")
            parsed_mode = arg
        else:
            raise ValueError(f"Invalid argument: {arg}")
    
    if parsed_ttl < 0:
        raise ValueError("TTL must be non-negative")
    
    if parsed_mode is not None and parsed_mode not in ("seq", "rep"):
        raise ValueError(f"Invalid mode: {parsed_mode}. Must be 'seq' or 'rep'")
    
    # Convert string to bytes if needed
    if isinstance(data, str):
        data = data.encode('utf-8')
    
    # Build filename components
    expiry = int(time.time()) + parsed_ttl if parsed_ttl > 0 else 0
    
    # Sequence number for FIFO mode
    seq_part = ""
    if parsed_mode == "seq":
        seq_part = _next_seq(name)
    
    # Random suffix (unless replacement mode)
    suffix_part = ""
    if parsed_mode != "rep":
        suffix_part = f"-{_random_suffix()}"
    
    # Expiry part
    expiry_part = f".{expiry}" if expiry > 0 else ""
    
    filename = f"{name}{seq_part}{suffix_part}{expiry_part}"
    filepath = TUPLEDIR / filename
    
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


def _try_read_tuple_atomic(pattern: str, consume: bool) -> bytes:
    """Try to atomically read (and optionally consume) a tuple matching the pattern.
    
    This function implements the same locking strategy as the shell and Tcl versions:
    - For consume operations: Use file locking for atomic read-and-delete
    - For read-only operations: Simple read without locking
    - Retry up to 2 times to handle race conditions
    """
    retry_count = 0
    
    while retry_count < 2:
        matches = _find_matching_tuples(pattern)
        found_any = len(matches) > 0
        
        for filepath in matches:
            if consume:
                # For consume operations, use atomic read-and-delete with locking
                try:
                    with _file_lock(filepath, timeout=0.1):  # Short lock timeout for retry
                        with open(filepath, 'rb') as f:
                            data = f.read()
                        # Successfully read, now delete
                        filepath.unlink()
                        return data
                except (FileNotFoundError, TupleNotFound, LockTimeout):
                    # Lock failed or file disappeared, try next file
                    continue
            else:
                # For read-only operations, simple read without locking
                try:
                    with open(filepath, 'rb') as f:
                        return f.read()
                except FileNotFoundError:
                    # File disappeared, try next file
                    continue
        
        if not found_any:
            raise TupleNotFound(f"No tuple matching '{pattern}'")
        
        # All files were locked by others or disappeared, try one more time
        retry_count += 1
    
    # Give up after retries
    raise TupleNotFound(f"No tuple matching '{pattern}'")


def _wait_for_tuple(pattern: str, consume: bool, timeout: Optional[float]) -> bytes:
    """Wait for a tuple matching the pattern with optional timeout."""
    if timeout == once:
        # Non-blocking mode
        return _try_read_tuple_atomic(pattern, consume)
    
    # Blocking mode with optional timeout
    start_time = time.time()
    
    while True:
        try:
            return _try_read_tuple_atomic(pattern, consume)
        except TupleNotFound:
            pass  # Continue waiting
        
        # Check timeout
        if timeout is not None and timeout > 0:
            elapsed = time.time() - start_time
            if elapsed >= timeout:
                raise TimeoutError(f"Timeout waiting for tuple '{pattern}'")
        
        time.sleep(0.1)


def inp(name_pattern: str, timeout: Optional[float] = None) -> bytes:
    """
    Input (read and remove) a tuple matching the pattern.
    
    Args:
        name_pattern: Pattern to match tuple names (supports * and ? wildcards)
        timeout: None = block forever, once = non-blocking, positive = timeout in seconds
    
    Returns:
        Tuple data as bytes
        
    Raises:
        TupleNotFound: If no matching tuple (non-blocking mode)
        TimeoutError: If timeout exceeded
    """
    _cleanup_expired()
    return _wait_for_tuple(name_pattern, consume=True, timeout=timeout)


def rd(name_pattern: str, timeout: Optional[float] = None) -> bytes:
    """Read (peek) a tuple without removing it.
    
    Args:
        name_pattern: Pattern to match tuple names (supports * and ? wildcards)
        timeout: None = block forever, once = non-blocking, positive = timeout in seconds
    
    Returns:
        Tuple data as bytes
        
    Raises:
        TupleNotFound: If no matching tuple (non-blocking mode)
        TimeoutError: If timeout exceeded
    """
    _cleanup_expired()
    return _wait_for_tuple(name_pattern, consume=False, timeout=timeout)


def ls(pattern: str = "*") -> List[str]:
    """List all tuple names matching the pattern with counts.
    
    Args:
        pattern: Pattern to match (default: "*" for all)
        
    Returns:
        List of strings in format "count name" for each tuple name
    """
    _cleanup_expired()
    
    name_counts = {}
    for filepath in TUPLEDIR.glob(pattern + "*" if not ('*' in pattern or '?' in pattern) else pattern):
        if filepath.name.startswith('.'):
            continue  # Skip hidden files
        if not _is_expired(filepath):
            try:
                name, _, _ = _parse_filename(filepath.name)
                name_counts[name] = name_counts.get(name, 0) + 1
            except ValueError:
                continue
    
    # Format as "count name" and sort
    result = [f"{count} {name}" for name, count in name_counts.items()]
    return sorted(result)


def clear() -> None:
    """Remove all tuples from the tuple space."""
    for filepath in TUPLEDIR.glob("*"):
        try:
            filepath.unlink()
        except FileNotFoundError:
            pass

