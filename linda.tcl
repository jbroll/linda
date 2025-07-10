package provide linda 1.0

namespace eval linda {
    variable TUPLEDIR $::env(LINDA_DIR)
    if {![info exists ::env(LINDA_DIR)] || $::env(LINDA_DIR) eq ""} {
        variable TUPLEDIR "/tmp/linda"
    }
    file mkdir $TUPLEDIR

    variable LOCK_TIMEOUT 5

    proc _now {} {
        return [clock seconds]
    }

    proc _expire_tuples {} {
        variable TUPLEDIR
        set now [_now]
        foreach file [glob -nocomplain -directory $TUPLEDIR *.*] {
            set base [file tail $file]
            # Check if filename ends with .DIGITS (expiry timestamp)
            if {[regexp {\.([0-9]+)$} $base -> expiry]} {
                if {$now >= $expiry} {
                    catch {file delete -force $file}
                }
            }
        }
    }

    proc _is_expired {file} {
        set base [file tail $file]
        if {[regexp {\.([0-9]+)$} $base -> expiry]} {
            return [expr {[clock seconds] >= $expiry}]
        }
        return 0
    }

    proc _filelock {lockname} {
        variable LOCK_TIMEOUT
        set lockpath "${lockname}.lock"
        set start [clock seconds]
        
        while 1 {
            # Try to create lock file atomically
            if {![catch {
                set fd [open $lockpath {WRONLY CREAT EXCL}]
                puts $fd [pid]
                close $fd
            }]} {
                return 1
            }
            
            # Check if lock file exists and validate PID
            if {[file exists $lockpath]} {
                set pid ""
                catch {
                    set fd [open $lockpath r]
                    set pid [string trim [read $fd]]
                    close $fd
                }
                
                if {[string is integer -strict $pid]} {
                    # Check if process is still running
                    if {[catch {exec kill -0 $pid 2>/dev/null}]} {
                        catch {file delete -force $lockpath}
                        puts stderr "Removed stale lock held by PID $pid"
                        continue
                    }
                } else {
                    catch {file delete -force $lockpath}
                    puts stderr "Removed corrupt lock file"
                    continue
                }
            }
            
            after 50
            set now [clock seconds]
            if {($now - $start) >= $LOCK_TIMEOUT} {
                puts stderr "Timeout acquiring lock $lockpath"
                return 0
            }
        }
    }

    proc _fileunlock {lockname} {
        catch {file delete -force "${lockname}.lock"}
    }

    proc _next_seq {name} {
        variable TUPLEDIR
        set seqfile [file join $TUPLEDIR ".${name}.seq"]
        
        if {![_filelock $seqfile]} {
            error "Failed to acquire sequence lock for $name"
        }
        
        set seq 0
        if {[file exists $seqfile]} {
            catch {
                set fd [open $seqfile r]
                set seq [string trim [read $fd]]
                close $fd
            }
        }
        
        incr seq
        set fd [open $seqfile w]
        puts $fd [format "%08d" $seq]
        close $fd
        
        _fileunlock $seqfile
        return [format "-%08d" $seq]
    }

    proc _hex {{bytes 4} {prefix ""}} {
        set chars "0123456789abcdef"
        set result $prefix
        for {set i 0} {$i < [expr {$bytes * 2}]} {incr i} {
            append result [string index $chars [expr {int(rand() * 16)}]]
        }
        return $result
    }

    proc out {name data args} {
        variable TUPLEDIR
        _expire_tuples

        set ttl 0
        set seq ""
        set hex "-[_hex]"
        
        foreach arg $args {
            if {$arg eq "rep"} {
                set hex ""
            } elseif {$arg eq "seq"} {
                set seq [_next_seq $name]
            } elseif {[string is integer -strict $arg] && $arg >= 0} {
                set ttl $arg
            } else {
                error "Invalid argument: $arg"
            }
        }

        set expires ""
        if {$ttl > 0} {
            set expires ".[expr {[clock seconds] + $ttl}]"
        }

        set filename "${name}${seq}${hex}${expires}"
        set filepath [file join $TUPLEDIR $filename]

        # Write atomically: write to tmp then rename
        set tmpfile "${filepath}.tmp.[pid]"
        set fd [open $tmpfile w]
        puts -nonewline $fd $data
        close $fd
        file rename $tmpfile $filepath
    }

    proc inp {pattern args} {
        variable TUPLEDIR
        _expire_tuples

        set mode "wait"
        set timeout 0
        
        if {[llength $args] >= 1} {
            set arg [lindex $args 0]
            if {$arg eq "once"} {
                set mode "once"
            } elseif {[string is integer -strict $arg]} {
                set mode "timeout"
                set timeout $arg
            } else {
                error "Invalid timeout argument: $arg"
            }
        }

        set start [clock seconds]
        set deadline 0
        if {$mode eq "timeout"} {
            set deadline [expr {$start + $timeout}]
        }

        while 1 {
            foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
                if {[_is_expired $file]} continue
                
                set fd [open $file r]
                set data [read $fd]
                close $fd
                file delete -force $file
                return $data
            }

            if {$mode eq "once"} {
                error "No tuple matching \"$pattern\""
            } elseif {$mode eq "timeout"} {
                set now [clock seconds]
                if {$now >= $deadline} {
                    error "Timeout waiting for tuple \"$pattern\""
                }
            }
            
            after 100
            update
        }
    }

    proc rd {pattern args} {
        variable TUPLEDIR
        _expire_tuples

        set mode "wait"
        if {[llength $args] >= 1 && [lindex $args 0] eq "once"} {
            set mode "once"
        }

        while 1 {
            foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
                if {[_is_expired $file]} continue
                
                set fd [open $file r]
                set data [read $fd]
                close $fd
                return $data
            }
            
            if {$mode eq "once"} {
                error "No tuple matching \"$pattern\""
            }
            
            after 100
            update
        }
    }

    proc ls {args} {
        variable TUPLEDIR
        _expire_tuples

        set pattern "*"
        if {[llength $args] >= 1} {
            set pattern [lindex $args 0]
        }

        set names [dict create]
        foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
            if {[_is_expired $file]} continue
            
            set base [file tail $file]
            # Extract name from filename (everything before first hyphen or dot)
            set name $base
            if {[regexp {^([^-\.]+)} $base -> extracted]} {
                set name $extracted
            }
            
            if {[dict exists $names $name]} {
                dict incr names $name
            } else {
                dict set names $name 1
            }
        }
        
        set result [list]
        dict for {name count} $names {
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
}