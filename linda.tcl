package provide linda 1.0

namespace eval linda {
    variable TUPLEDIR [::env(LINDA_DIR)]
    if {![info exists ::env(LINDA_DIR)] || $::env(LINDA_DIR) eq ""} {
        variable TUPLEDIR "/tmp/linda"
    }
    file mkdir $TUPLEDIR

    proc _now {} {
        return [clock seconds]
    }

    proc _expire_tuples {} {
        variable TUPLEDIR
        set now [_now]
        foreach file [glob -nocomplain -directory $TUPLEDIR *] {
            set base [file tail $file]
            # Expect format: name.expiry.rand
            set parts [split $base "."]
            if {[llength $parts] < 4} continue
            set expiry [lindex $parts 1]
            if {[string is integer -strict $expiry] && $expiry != 0} {
                if {$now >= $expiry} {
                    catch {file delete -force $file}
                    catch {file delete -force "${file}.lock"}
                }
            }
        }
    }

    proc _is_expired {file} {
        set base [file tail $file]
        set parts [split $base "."]
        if {[llength $parts] < 4} {
            return 1
        }
        set expiry [lindex $parts 1]
        if {$expiry eq "0"} {
            return 0
        }
        if {[string is integer -strict $expiry]} {
            return [expr {[clock seconds] >= $expiry}]
        }
        return 1
    }

    proc _lock_file {file} {
        # Use atomic file link to create lock file
        set lockfile "${file}.lock"
        catch {
            file link $file $lockfile
        } result options
        if {[string match "*File exists*" $options(-errorinfo)]} {
            return ""
        } elseif {[catch {file link $file $lockfile}]} {
            return ""
        } else {
            return $lockfile
        }
    }

    proc _unlock_file {lockfile} {
        catch {file delete -force $lockfile}
    }

    proc _find_and_lock {pattern} {
        variable TUPLEDIR
        foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
            if {[_is_expired $file]} continue
            set lockfile [_lock_file $file]
            if {$lockfile ne ""} {
                return [list $file $lockfile]
            }
        }
        return [list "" ""]
    }

    proc out {name data args} {
        variable TUPLEDIR
        _expire_tuples

        set ttl 0
        if {[llength $args] >= 1} {
            set ttl [lindex $args 0]
            if {![string is integer -strict $ttl] || $ttl < 0} {
                error "TTL must be a non-negative integer"
            }
        }

        set expiry 0
        if {$ttl > 0} {
            set expiry [expr {[clock seconds] + $ttl}]
        }

        # generate random suffix (6 chars)
        set rand [string tolower [join [list] ""]]
        foreach i {1 2 3 4 5 6} {
            append rand [string index {abcdefghijklmnopqrstuvwxyz0123456789} [expr {int(rand()*36)}]]
        }

        set filename "${name}.${expiry}.${rand}"
        set filepath [file join $TUPLEDIR $filename]

        # Write atomically: write to tmp then rename
        set tmpfile [file join $TUPLEDIR "tmp.${name}.$$"]
        set f [open $tmpfile w]
        puts -nonewline $f $data
        close $f
        file rename -force $tmpfile $filepath
    }

    proc inp {pattern args} {
        variable TUPLEDIR
        _expire_tuples

        set mode "block"
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

        while 1 {
            set res [_find_and_lock $pattern]
            set file [lindex $res 0]
            set lockfile [lindex $res 1]
            if {$file ne ""} {
                set f [open $file r]
                set data [read $f]
                close $f
                file delete -force $file
                _unlock_file $lockfile
                return $data
            }

            if {$mode eq "once"} {
                error "No tuple matching \"$pattern\""
            } elseif {$mode eq "timeout"} {
                if {([clock seconds] - $start) >= $timeout} {
                    error "Timeout waiting for tuple \"$pattern\""
                }
            }
            after 100
            update
        }
    }

    proc rd {pattern} {
        variable TUPLEDIR
        _expire_tuples

        while 1 {
            set res [_find_and_lock $pattern]
            set file [lindex $res 0]
            set lockfile [lindex $res 1]
            if {$file ne ""} {
                set f [open $file r]
                set data [read $f]
                close $f
                _unlock_file $lockfile
                return $data
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

        set result [list]
        foreach file [glob -nocomplain -directory $TUPLEDIR "${pattern}*"] {
            if {[_is_expired $file]} continue
            lappend result [file tail $file]
        }
        return $result
    }
}
