#!/usr/bin/env python3

import unittest
import os
import time
import tempfile
import shutil
from pathlib import Path

# Set up test environment before importing linda
test_dir = "/tmp/lindatest"
os.environ["LINDA_DIR"] = test_dir

# Now import linda
import linda


class TestLinda(unittest.TestCase):
    """Test suite for Linda tuple space implementation."""
    
    @classmethod
    def setUpClass(cls):
        """Set up test environment once for all tests."""
        cls.test_dir = Path(test_dir)
        if cls.test_dir.exists():
            shutil.rmtree(cls.test_dir)
        cls.test_dir.mkdir(parents=True, exist_ok=True)
    
    def setUp(self):
        """Clean up before each test."""
        linda.clear()
    
    def tearDown(self):
        """Clean up after each test."""
        linda.clear()
    
    @classmethod
    def tearDownClass(cls):
        """Clean up test directory after all tests."""
        if cls.test_dir.exists():
            shutil.rmtree(cls.test_dir)

    def test_basic_out_inp(self):
        """Test basic out/inp operation."""
        linda.out("test1", "hello")
        result = linda.inp("test1", linda.once)
        self.assertEqual(result, b"hello")

    def test_tuple_expiry(self):
        """Test tuple expiry after TTL."""
        linda.out("expireme", "short-lived", 1)
        time.sleep(2)
        with self.assertRaises(linda.TupleNotFound):
            linda.inp("expireme", linda.once)

    def test_sequence_numbering(self):
        """Test sequence numbering format."""
        linda.out("seqtest", "seq test", mode="seq")
        result = linda.rd("seqtest", linda.once)
        self.assertEqual(result, b"seq test")

    def test_ttl_with_sequence(self):
        """Test TTL with sequence numbering."""
        linda.out("both", "combined", 5, "seq")
        result = linda.rd("both", linda.once)
        self.assertEqual(result, b"combined")

    def test_rd_does_not_consume(self):
        """Test rd command does not consume tuple."""
        linda.out("readtest", "read me")
        result1 = linda.rd("readtest", linda.once)
        result2 = linda.rd("readtest", linda.once)
        self.assertEqual(result1, b"read me")
        self.assertEqual(result2, b"read me")

    def test_ls_command(self):
        """Test ls command shows correct counts."""
        linda.clear()
        linda.out("listme", "one")
        linda.out("listme", "two")
        linda.out("another", "three")
        lsout = linda.ls()
        self.assertGreater(len(lsout), 0)
        # Check that we have the expected tuple names
        names = [entry.split()[1] for entry in lsout]
        self.assertIn("listme", names)
        self.assertIn("another", names)

    def test_cleanup_expired(self):
        """Test expired tuples are cleaned up."""
        linda.out("tempkey", "soon gone", 1)
        time.sleep(2)
        # Trigger cleanup by running ls
        linda.ls()
        # Try to read the expired tuple - should fail
        with self.assertRaises(linda.TupleNotFound):
            linda.rd("tempkey", linda.once)

    def test_replacement_semantics(self):
        """Test replacement semantics with rep mode."""
        linda.out("reptest", "first", mode="rep")
        linda.out("reptest", "second", mode="rep")
        # Should only have one tuple and it should be the second one
        result = linda.inp("reptest", linda.once)
        self.assertEqual(result, b"second")

    def test_multiple_tuples(self):
        """Test multiple tuples with same name."""
        linda.out("multitest", "data1")
        linda.out("multitest", "data2")
        # Should be able to read both tuples (order may vary)
        result1 = linda.inp("multitest", linda.once)
        result2 = linda.inp("multitest", linda.once)
        self.assertTrue(len(result1) > 0)
        self.assertTrue(len(result2) > 0)
        # Should get both data values
        results = {result1, result2}
        self.assertEqual(results, {b"data1", b"data2"})

    def test_fifo_semantics(self):
        """Test FIFO semantics with seq mode."""
        linda.out("fifotest", "first", mode="seq")
        linda.out("fifotest", "second", mode="seq")
        linda.out("fifotest", "third", mode="seq")
        # Should retrieve in FIFO order (first in, first out)
        result1 = linda.inp("fifotest", linda.once)
        result2 = linda.inp("fifotest", linda.once)
        result3 = linda.inp("fifotest", linda.once)
        self.assertEqual(result1, b"first")
        self.assertEqual(result2, b"second")
        self.assertEqual(result3, b"third")

    def test_blocking_timeout(self):
        """Test inp with timeout returns failure when no match."""
        start_time = time.time()
        with self.assertRaises(TimeoutError):
            linda.inp("nonexistent", 1)
        end_time = time.time()
        elapsed = end_time - start_time
        # Should have waited approximately 1 second
        self.assertGreaterEqual(elapsed, 1.0)
        self.assertLessEqual(elapsed, 2.0)

    def test_clear_command(self):
        """Test clear command removes all tuples."""
        linda.out("cleartest1", "test1")
        linda.out("cleartest2", "test2")
        linda.clear()
        # Try to read any tuple - should fail
        with self.assertRaises(linda.TupleNotFound):
            linda.rd("cleartest1", linda.once)
        with self.assertRaises(linda.TupleNotFound):
            linda.rd("cleartest2", linda.once)

    def test_pattern_matching(self):
        """Test pattern matching with wildcards."""
        linda.clear()
        linda.out("pattern1", "data1")
        linda.out("pattern2", "data2")
        linda.out("other", "data3")
        # Should match pattern* but not other
        result = linda.rd("pattern*", linda.once)
        # Should get one of the pattern tuples
        self.assertIn(result, [b"data1", b"data2"])

    def test_non_blocking_inp(self):
        """Test non-blocking inp with once flag."""
        # Try to read from empty tuple space
        with self.assertRaises(linda.TupleNotFound):
            linda.inp("nonexistent", linda.once)

    def test_non_blocking_rd(self):
        """Test non-blocking rd with once flag."""
        # Try to read from empty tuple space
        with self.assertRaises(linda.TupleNotFound):
            linda.rd("nonexistent", linda.once)

    def test_empty_data(self):
        """Test storing and retrieving empty data."""
        linda.out("empty", "")
        result = linda.inp("empty", linda.once)
        self.assertEqual(result, b"")

    def test_binary_data(self):
        """Test storing and retrieving binary-like data."""
        binary_data = b"\x00\x01\x02\xFF"
        linda.out("binary", binary_data)
        result = linda.inp("binary", linda.once)
        self.assertEqual(result, binary_data)

    def test_large_data(self):
        """Test storing and retrieving large data."""
        large_data = "A" * 10000
        linda.out("large", large_data)
        result = linda.inp("large", linda.once)
        self.assertEqual(len(result), 10000)
        self.assertEqual(result, large_data.encode('utf-8'))

    def test_multiple_operations(self):
        """Test multiple concurrent operations."""
        linda.clear()
        # Store multiple tuples
        for i in range(10):
            linda.out(f"multi{i}", f"data{i}")
        
        # Read them all back
        count = 0
        for i in range(10):
            try:
                linda.inp(f"multi{i}", linda.once)
                count += 1
            except linda.TupleNotFound:
                pass
        
        self.assertEqual(count, 10)

    def test_ls_with_pattern(self):
        """Test ls command with pattern matching."""
        linda.clear()
        linda.out("prefix1", "data1")
        linda.out("prefix2", "data2")
        linda.out("other", "data3")
        result = linda.ls("prefix*")
        # Should return entries for prefix1 and prefix2
        self.assertEqual(len(result), 2)

    def test_string_vs_bytes(self):
        """Test that strings are properly encoded/decoded."""
        # Test with string input
        linda.out("string_test", "hello world")
        result = linda.inp("string_test", linda.once)
        self.assertEqual(result, b"hello world")
        
        # Test with bytes input
        linda.out("bytes_test", b"hello bytes")
        result = linda.inp("bytes_test", linda.once)
        self.assertEqual(result, b"hello bytes")

    def test_invalid_arguments(self):
        """Test error handling for invalid arguments."""
        # Negative TTL should raise ValueError
        with self.assertRaises(ValueError):
            linda.out("test", "data", -1)
        
        # Invalid argument to out should raise ValueError
        with self.assertRaises(ValueError):
            linda.out("test", "data", "invalid")

    def test_complex_filenames(self):
        """Test that complex tuple names work correctly."""
        # Test names with special characters
        linda.out("test-name", "data1")
        linda.out("test.name", "data2")
        linda.out("test_name", "data3")
        
        # Should be able to retrieve all
        result1 = linda.inp("test-name", linda.once)
        result2 = linda.inp("test.name", linda.once)
        result3 = linda.inp("test_name", linda.once)
        
        self.assertEqual(result1, b"data1")
        self.assertEqual(result2, b"data2")
        self.assertEqual(result3, b"data3")

    def test_concurrent_access_simulation(self):
        """Test behavior under simulated concurrent access."""
        # Create multiple tuples with same name
        for i in range(5):
            linda.out("concurrent", f"data{i}")
        
        # Consume them all
        results = []
        for i in range(5):
            try:
                result = linda.inp("concurrent", linda.once)
                results.append(result)
            except linda.TupleNotFound:
                break
        
        # Should have gotten all 5
        self.assertEqual(len(results), 5)
        
        # Should not be able to get another
        with self.assertRaises(linda.TupleNotFound):
            linda.inp("concurrent", linda.once)

    def test_mixed_semantics_warning(self):
        """Test that mixing normal and replacement semantics works as documented."""
        # This test documents the limitation mentioned in README
        # Normal out creates files with random suffix
        linda.out("mixed", "normal")
        
        # Replacement out creates file without suffix
        linda.out("mixed", "replacement", "rep")
        
        # Should be able to read something (undefined which one)
        result = linda.rd("mixed", linda.once)
        self.assertIn(result, [b"normal", b"replacement"])


def run_tests():
    """Run all tests with verbose output."""
    # Create a test suite
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromTestCase(TestLinda)
    
    # Run tests with verbose output
    runner = unittest.TextTestRunner(verbosity=2, buffer=True)
    result = runner.run(suite)
    
    # Print summary
    print(f"\nRan {result.testsRun} tests")
    if result.failures:
        print(f"Failures: {len(result.failures)}")
    if result.errors:
        print(f"Errors: {len(result.errors)}")
    
    if result.wasSuccessful():
        print("All tests passed!")
        return 0
    else:
        print("Some tests failed!")
        return 1


if __name__ == "__main__":
    import sys
    sys.exit(run_tests())
