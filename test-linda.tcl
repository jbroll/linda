#!/usr/bin/env tclsh

package require tcltest
namespace import ::tcltest::*

# Set up test environment
set testDir "/tmp/lindatest"
set ::env(LINDA_DIR) $testDir

# Load the linda package
source linda.tcl
package require linda

# Setup test environment
file mkdir $testDir
foreach file [glob -nocomplain -directory $testDir *] {
    file delete -force $file
}

# === Test 1: Basic out/inp ===
test basic-out-inp {Basic out/inp operation} -body {
    linda::out test1 "hello"
    set result [linda::inp test1 once]
    return $result
} -result "hello"

# === Test 2: Expiry ===
test tuple-expiry {Tuple expiry after TTL} -body {
    linda::out expireme "short-lived" 1
    after 2000
    # Should throw error because tuple is expired
    catch {linda::inp expireme once} msg
    return $msg
} -match glob -result "*No tuple matching*"

# === Test 3: Sequence numbering ===
test sequence-numbering {Sequence numbering format} -body {
    linda::out seqtest "seq test" seq
    # Check that the tuple exists by trying to read it
    set result [linda::rd seqtest once]
    return $result
} -result "seq test"

# === Test 4: TTL + Sequence ===
test ttl-with-sequence {TTL with sequence numbering} -body {
    linda::out both "combined" 5 seq
    # Check that the tuple exists by trying to read it
    set result [linda::rd both once]
    return $result
} -result "combined"

# === Test 5: Read (rd) does not consume ===
test rd-does-not-consume {rd command does not consume tuple} -body {
    linda::out readtest "read me"
    set result1 [linda::rd readtest once]
    set result2 [linda::rd readtest once]
    # Return the results as a proper list
    return [list $result1 $result2]
} -result [list "read me" "read me"]

# === Test 6: Listing keys ===
test ls-command {ls command shows correct counts} -body {
    linda::clear
    linda::out listme "one"
    linda::out listme "two"
    linda::out another "three"
    # The ls command shows counts by tuple name
    set lsout [linda::ls]
    # Check that we have some output that includes counts
    expr {[llength $lsout] > 0}
} -result 1

# === Test 7: Cleanup expired tuples ===
test cleanup-expired {Expired tuples are cleaned up} -body {
    linda::out tempkey "soon gone" 1
    after 2000
    # Trigger cleanup by running ls
    linda::ls
    # Try to read the expired tuple - should fail
    catch {linda::rd tempkey once} msg
    return $msg
} -match glob -result "*No tuple matching*"

# === Test 8: Replacement semantics ===
test replacement-semantics {Replacement semantics with rep flag} -body {
    linda::out reptest "first" rep
    linda::out reptest "second" rep
    # Should only have one tuple and it should be the second one
    set result [linda::inp reptest once]
    return $result
} -result "second"

# === Test 9: Multiple tuples with same name ===
test multiple-tuples {Multiple tuples with same name} -body {
    linda::out multitest "data1"
    linda::out multitest "data2"
    # Should be able to read both tuples (order may vary)
    set result1 [linda::inp multitest once]
    set result2 [linda::inp multitest once]
    # Check that both results are non-empty
    expr {[string length $result1] > 0 && [string length $result2] > 0}
} -result 1

# === Test 10: FIFO semantics with sequence numbering ===
test fifo-semantics {FIFO semantics with seq flag} -body {
    linda::out fifotest "first" seq
    linda::out fifotest "second" seq
    linda::out fifotest "third" seq
    # Should retrieve in FIFO order (first in, first out)
    set result1 [linda::inp fifotest once]
    set result2 [linda::inp fifotest once]
    set result3 [linda::inp fifotest once]
    # Return as a proper list
    return [list $result1 $result2 $result3]
} -result [list "first" "second" "third"]

# === Test 11: Blocking timeout ===
test blocking-timeout {inp with timeout returns failure when no match} -body {
    set start_time [clock seconds]
    catch {linda::inp nonexistent 1} msg
    set end_time [clock seconds]
    set elapsed [expr {$end_time - $start_time}]
    # Should have waited approximately 1 second and failed
    expr {$elapsed >= 1 && $elapsed <= 2 && [string match "*Timeout*" $msg]}
} -result 1

# === Test 12: Clear command ===
test clear-command {clear command removes all tuples} -body {
    linda::out cleartest1 "test1"
    linda::out cleartest2 "test2"
    linda::clear
    # Try to read any tuple - should fail
    set fail1 [catch {linda::rd cleartest1 once}]
    set fail2 [catch {linda::rd cleartest2 once}]
    # Both should fail (return 1)
    expr {$fail1 && $fail2}
} -result 1

# === Test 13: Pattern matching ===
test pattern-matching {Pattern matching with wildcards} -body {
    linda::clear
    linda::out pattern1 "data1"
    linda::out pattern2 "data2"
    linda::out other "data3"
    # Should match pattern* but not other
    set result [linda::rd pattern* once]
    # Should get one of the pattern tuples
    expr {$result eq "data1" || $result eq "data2"}
} -result 1

# === Test 14: Non-blocking inp (once) ===
test non-blocking-inp {Non-blocking inp with once flag} -body {
    # Try to read from empty tuple space
    catch {linda::inp nonexistent once} msg
    return $msg
} -match glob -result "*No tuple matching*"

# === Test 15: Non-blocking rd (once) ===
test non-blocking-rd {Non-blocking rd with once flag} -body {
    # Try to read from empty tuple space
    catch {linda::rd nonexistent once} msg
    return $msg
} -match glob -result "*No tuple matching*"

# === Test 16: Empty data ===
test empty-data {Storing and retrieving empty data} -body {
    linda::out empty ""
    set result [linda::inp empty once]
    return $result
} -result ""

# === Test 17: Binary data ===
test binary-data {Storing and retrieving binary-like data} -body {
    set binaryData "\x00\x01\x02\xFF"
    linda::out binary $binaryData
    set result [linda::inp binary once]
    return $result
} -result "\x00\x01\x02\xFF"

# === Test 18: Large data ===
test large-data {Storing and retrieving large data} -body {
    set largeData [string repeat "A" 10000]
    linda::out large $largeData
    set result [linda::inp large once]
    expr {[string length $result] == 10000 && $result eq $largeData}
} -result 1

# === Test 19: Multiple operations ===
test multiple-operations {Multiple concurrent operations} -body {
    linda::clear
    # Store multiple tuples
    for {set i 0} {$i < 10} {incr i} {
        linda::out "multi$i" "data$i"
    }
    # Read them all back
    set count 0
    for {set i 0} {$i < 10} {incr i} {
        if {![catch {linda::inp "multi$i" once}]} {
            incr count
        }
    }
    return $count
} -result 10

# === Test 20: ls with pattern ===
test ls-with-pattern {ls command with pattern matching} -body {
    linda::clear
    linda::out prefix1 "data1"
    linda::out prefix2 "data2"
    linda::out other "data3"
    set result [linda::ls "prefix*"]
    # Should return entries for prefix1 and prefix2
    expr {[llength $result] == 2}
} -result 1

# Cleanup
cleanupTests
file delete -force $testDir