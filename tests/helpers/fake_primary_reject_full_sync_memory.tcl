# A fake primary that accepts the normal replication handshake, rejects the
# full-sync memory budget extension, and records every command it receives.

set port [lindex $argv 0]
set command_file [lindex $argv 1]

proc read_command {sock} {
    set marker [read $sock 1]
    if {$marker eq ""} {
        return {}
    }
    if {$marker ne "*"} {
        return [string trim "$marker[gets $sock]"]
    }

    set argc [gets $sock]
    set command {}
    for {set j 0} {$j < $argc} {incr j} {
        read $sock 1
        set len [gets $sock]
        set arg [read $sock $len]
        gets $sock
        lappend command $arg
    }
    return $command
}

proc record_command {command} {
    global command_file
    set fp [open $command_file a]
    puts $fp [join $command " "]
    close $fp
}

proc accept {sock host port} {
    set received_command 0
    while {![eof $sock]} {
        set command [read_command $sock]
        if {[llength $command] == 0} {
            break
        }
        set received_command 1
        record_command $command

        set name [string tolower [lindex $command 0]]
        if {$name eq "ping"} {
            puts $sock "+PONG"
        } elseif {$name eq "replconf" &&
                  [string equal -nocase [lindex $command 1] full-sync-memory-budget]} {
            puts $sock "-ERR Unrecognized REPLCONF option"
        } elseif {$name eq "replconf"} {
            puts $sock "+OK"
        } elseif {$name eq "psync"} {
            puts $sock "-NOMASTERLINK fake primary has no dataset"
            break
        } else {
            puts $sock "-ERR unexpected command"
            break
        }
        flush $sock
    }
    close $sock
    if {$received_command} {
        set ::done 1
    }
}

socket -server accept $port
after 10000 set ::done 1
vwait ::done
