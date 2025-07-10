package provide linda 1.0

# Flexible resource management
proc with {resource as variable {free {}} {block {}}} {
    if {$as ne "as"} {
        lassign [list $resource $variable] variable resource
    }
    uplevel [list set $variable $resource]
    if {$block eq {}} {
        set block $free
        set free [subst -nocommands {
            if {[info command \$$variable] eq ""} {
                chan close \$$variable
            } else {
                \$$variable close
            }
        }]
    }
    try {
        uplevel $block
    } finally {
        uplevel $free
    }
}

# File locking utilities
namespace eval filelock {
    variable TIMEOUT 5

    proc acquire {lockname} {
        variable TIMEOUT
        set lockpath "${lockname}.lock"
        set start [clock seconds]
        
        while {([clock seconds] - $start) < $TIMEOUT} {
            # Try atomic lock creation
            try {
                with [open $lockpath {WRONLY CREAT EXCL}] as fd {
                    puts $fd [pid]
                }
                return 1
            } on error {} {
                # Lock exists, check if stale
                if {[file exists $lockpath]} {
                    try {
                        with [open $lockpath r] as fd {
                            set pid [string trim [read $fd]]
                        }
                        if {[string is integer -strict $pid] && 
                            [catch {exec kill -0 $pid 2>/dev/null}]} {
                            file delete -force $lockpath
                            continue
                        }
                    } on error {} {
                        # Corrupt lock file
                        file delete -force $lockpath
                        continue
                    }
                }
                after 50
            }
        }
        return 0
    }
    
    proc release {lockname} {
        catch {file delete -force "${lockname}.lock"}
    }
    
    proc with-lock {lockname script} {
        if {![acquire $lockname]} {
            error "Failed to acquire lock: $lockname"
        }
        try {
            uplevel 1 $script
        } finally {
            release $lockname
        }
    }
    
    namespace export acquire release with-lock
    namespace ensemble create
}

# Linda tuple space implementation
namespace eval linda {
    variable TUPLEDIR $::env(LINDA_DIR)
    if {![info exists ::env(LINDA_DIR)] || $::env(LINDA_DIR) eq ""} {
        variable TUPLEDIR "/tmp/linda"
    }
    file mkdir $TUPLEDIR

    proc _expire_tuples {} {
        variable TUPLEDIR
        set now [clock seconds]
        foreach file [glob -nocomplain -directory $TUPLEDIR *.*] {
            if {[regexp {\.(\d+)$} [file tail $file] -> expiry] && $now >= $expiry} {
                catch {file delete -force $file}
            }
        }
    }

    proc _is_expired {file} {
        return [expr {
            [regexp {\.(\d+)$} [file tail $file] -> expiry] && 
            [clock seconds] >= $expiry
        }]
    }

    proc _next_seq {name} {
        variable TUPLEDIR
        set seqfile [file join $TUPLEDIR ".${name}.seq"]
        
        filelock with-lock $seqfile {
            set seq 0
            if {[file exists $seqfile]} {
                with [open $seqfile r] as fd {
                    set seq [string trim [read $fd]]
                }
            }
            
            incr seq
            with [open $seqfile w] as fd {
                puts $fd [format "%08d" $seq]
            }
            
            return [format "-%08d" $seq]
        }
    }

    proc _random_hex {{bytes 4}} {
        return [format %0[expr {$bytes*2}]x [expr {int(rand() * (16**($bytes*2)))}]]
    }

    proc _atomic_write {filepath data} {
        set tmpfile "${filepath}.tmp.[pid].[_random_hex 2]"
        with [open $tmpfile w] as fd {
            puts -nonewline $fd $data
        }
        file rename -force $tmpfile $filepath
    }

    proc out {name data args} {
        variable TUPLEDIR
        _expire_tuples

        # Parse arguments using lassign for clean unpacking
        set ttl 0
        set seq ""
        set suffix "-[_random_hex]"
        
        foreach arg $args {
            switch -exact -- $arg {
                rep { set suffix "" }
                seq { set seq [_next_seq $name] }
                default {
                    if {[string is integer -strict $arg] && $arg >= 0} {
                        set ttl $arg
                    } else {
                        error "Invalid argument: $arg"
                    }
                }
            }
        }

        # Build filename and write atomically
        set expires [expr {$ttl > 0 ? ".[expr {[clock seconds] + $ttl}]" : ""}]
        set filepath [file join $TUPLEDIR "${name}${seq}${suffix}${expires}"]
        
        _atomic_write $filepath $data
    }

    proc _try_read_tuple {pattern consume} {
        variable TUPLEDIR
        
        foreach file [lsort [glob -nocomplain -directory $TUPLEDIR "${pattern}*"]] {
            if {[_is_expired $file]} continue
            
            # Lock-free read attempt
            try {
                with [open $file r] as fd {
                    set data [read $fd]
                }
                
                # If consuming, try to remove (may fail - that's ok)
                if {$consume} {
                    catch {file delete -force $file}
                }
                return $data
            } on error {} {
                # File disappeared between glob and open - continue to next
            }
        }
        return ""
    }

    proc _wait_for_tuple {pattern consume mode timeout} {
        set start [clock seconds]
        set deadline [expr {$mode eq "timeout" ? $start + $timeout : 0}]

        while 1 {
            set data [_try_read_tuple $pattern $consume]
            if {$data ne ""} {
                return $data
            }

            switch $mode {
                once {
                    error "No tuple matching \"$pattern\""
                }
                timeout {
                    if {[clock seconds] >= $deadline} {
                        error "Timeout waiting for tuple \"$pattern\""
                    }
                }
            }
            
            after 100
        }
    }

    proc inp {pattern args} {
        _expire_tuples
        
        # Parse timeout using lassign for clean argument handling
        lassign $args timeout_arg
        
        if {$timeout_arg eq ""} {
            set mode wait
            set timeout 0
        } elseif {$timeout_arg eq "once"} {
            set mode once
            set timeout 0
        } elseif {[string is integer -strict $timeout_arg]} {
            set mode timeout
            set timeout $timeout_arg
        } else {
            error "Invalid timeout argument: $timeout_arg"
        }

        return [_wait_for_tuple $pattern 1 $mode $timeout]
    }

    proc rd {pattern args} {
        _expire_tuples
        
        # Parse timeout using lassign for clean argument handling
        lassign $args timeout_arg
        
        if {$timeout_arg eq ""} {
            set mode wait
            set timeout 0
        } elseif {$timeout_arg eq "once"} {
            set mode once
            set timeout 0
        } elseif {[string is integer -strict $timeout_arg]} {
            set mode timeout
            set timeout $timeout_arg
        } else {
            error "Invalid timeout argument: $timeout_arg"
        }
        
        return [_wait_for_tuple $pattern 0 $mode $timeout]
    }

    proc ls {args} {
        variable TUPLEDIR
        _expire_tuples

        lassign $args pattern
        if {$pattern eq ""} { set pattern "*" }
        
        # Use dict for cleaner counting
        set counts [dict create]
        foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
            if {[_is_expired $file]} continue
            
            # Extract tuple name (everything before first - or .)
            regexp {^([^-.]+)} [file tail $file] -> name
            dict incr counts $name
        }
        
        # Build result using dict for
        set result {}
        dict for {name count} $counts {
            lappend result "$count $name"
        }
        return [lsort $result]
    }

    proc clear {} {
        variable TUPLEDIR
        foreach file [glob -nocomplain -directory $TUPLEDIR *] {
            catch {file delete -force $file}
        }
    }

    # Export all public commands
    namespace export out inp rd ls clear
    namespace ensemble create
}
