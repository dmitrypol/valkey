proc full_sync_memory_fake_primary_commands {command_file} {
    if {![file exists $command_file]} {
        return ""
    }
    set fp [open $command_file r]
    set commands [read $fp]
    close $fp
    return $commands
}

start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
    test {swapdb full-sync memory admission percentage validates and round-trips} {
        assert_equal 0 [lindex [r config get repl-diskless-load-swapdb-max-memory-percent] 1]
        assert_equal OK [r config set repl-diskless-load-swapdb-max-memory-percent 95]
        assert_equal 95 [lindex [r config get repl-diskless-load-swapdb-max-memory-percent] 1]
        assert_equal OK [r config set repl-diskless-load-swapdb-max-memory-percent 100]
        assert_error {*argument must be between 0 and 100*} {
            r config set repl-diskless-load-swapdb-max-memory-percent 101
        }
        assert_error {*argument must be between 0 and 100*} {
            r config set repl-diskless-load-swapdb-max-memory-percent -1
        }
    }
}

start_server {tags {repl needs:config-maxmemory} overrides {save "" repl-backlog-size 1mb}} {
    set primary [srv 0 client]
    set primary_host [srv 0 host]
    set primary_port [srv 0 port]

    start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
        set replica [srv 0 client]
        $replica config set repl-diskless-load swapdb
        $replica replicaof $primary_host $primary_port
        wait_for_sync $replica

        test {a partial sync is allowed even when the full-sync memory budget is zero} {
            $replica config set repl-diskless-load-swapdb-max-memory-percent 95
            $replica config set maxmemory 0

            set partial_before [status $primary sync_partial_ok]
            set rejected_before [status $primary sync_full_rejected_memory]
            $replica client kill type primary
            $primary set partial-sync-memory allowed

            wait_for_condition 100 50 {
                [status $primary sync_partial_ok] > $partial_before &&
                [$replica get partial-sync-memory] eq "allowed"
            } else {
                fail "Replica did not complete partial synchronization"
            }
            assert_equal $rejected_before [status $primary sync_full_rejected_memory]
        }
    }
}

if {!$::tls} {
    start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
        set replica [srv 0 client]

        test {an unsupported primary fails closed before PSYNC} {
            set port [find_available_port $::baseport $::portcount]
            set command_file [tmpfile fake-primary-commands]
            set tclsh [info nameofexecutable]
            exec $tclsh tests/helpers/fake_primary_reject_full_sync_memory.tcl $port $command_file &
            wait_for_condition 50 50 {
                [catch {close [socket 127.0.0.1 $port]}] == 0
            } else {
                fail "Failed to start fake primary"
            }

            $replica set old-data retained
            $replica config set repl-diskless-load swapdb
            $replica config set repl-diskless-load-swapdb-max-memory-percent 95
            $replica replicaof 127.0.0.1 $port

            wait_for_condition 100 50 {
                [string match "*REPLCONF full-sync-memory-budget*" \
                    [full_sync_memory_fake_primary_commands $command_file]]
            } else {
                fail "Replica did not send its full-sync memory budget"
            }
            after 100
            assert_no_match "*PSYNC*" [full_sync_memory_fake_primary_commands $command_file]
            assert_equal retained [$replica get old-data]

            $replica replicaof no one
        }

        foreach {load_mode percent description} {
            swapdb 0 {the default configuration remains compatible with an unsupported primary}
            disabled 95 {non-swapdb loading omits the strict memory handshake}
        } {
            test $description {
                set port [find_available_port $::baseport $::portcount]
                set command_file [tmpfile fake-primary-commands]
                set tclsh [info nameofexecutable]
                exec $tclsh tests/helpers/fake_primary_reject_full_sync_memory.tcl $port $command_file &
                wait_for_condition 50 50 {
                    [catch {close [socket 127.0.0.1 $port]}] == 0
                } else {
                    fail "Failed to start fake primary"
                }

                $replica config set repl-diskless-load $load_mode
                $replica config set repl-diskless-load-swapdb-max-memory-percent $percent
                $replica replicaof 127.0.0.1 $port

                wait_for_condition 100 50 {
                    [string match "*PSYNC*" [full_sync_memory_fake_primary_commands $command_file]]
                } else {
                    fail "Replica did not reach PSYNC with admission inactive"
                }
                assert_no_match "*REPLCONF full-sync-memory-budget*" \
                    [full_sync_memory_fake_primary_commands $command_file]

                $replica replicaof no one
            }
        }
    }
}

start_server {tags {repl}} {
    test {REPLCONF accepts a full-sync memory budget} {
        assert_equal OK [r replconf full-sync-memory-budget 12345]
    }

    test {REPLCONF rejects invalid full-sync memory budgets} {
        assert_error {*invalid full-sync memory budget*} {
            r replconf full-sync-memory-budget -1
        }
        assert_error {*invalid full-sync memory budget*} {
            r replconf full-sync-memory-budget not-a-number
        }
        assert_error {*invalid full-sync memory budget*} {
            r replconf full-sync-memory-budget 18446744073709551616
        }
    }
}

start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
    set primary [srv 0 client]
    set primary_host [srv 0 host]
    set primary_port [srv 0 port]

    $primary config set repl-diskless-sync yes
    $primary config set repl-diskless-sync-delay 0
    $primary debug populate 2000 full-sync-memory 1000

    start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
        set replica [srv 0 client]
        $replica set old-data retained
        $replica config set repl-diskless-load swapdb
        $replica config set repl-diskless-load-swapdb-max-memory-percent 95

        set replica_used [status $replica used_memory]
        $replica config set maxmemory $replica_used

        set sync_full_before [status $primary sync_full]
        set rejected_before [status $primary sync_full_rejected_memory]
        if {$rejected_before eq ""} {
            set rejected_before 0
        }

        $replica replicaof $primary_host $primary_port

        test {swapdb full sync is rejected before it starts when memory is insufficient} {
            wait_for_condition 100 50 {
                [status $primary sync_full_rejected_memory] > $rejected_before
            } else {
                fail "Primary did not reject the full sync for insufficient replica memory"
            }

            assert_equal $sync_full_before [status $primary sync_full]
            assert_equal down [status $replica master_link_status]
            assert_equal retained [$replica get old-data]
        }

        test {swapdb full sync retries and succeeds after maxmemory is increased} {
            set primary_used [status $primary used_memory]
            set replica_used [status $replica used_memory]
            set allow_limit [expr {$replica_used + ($primary_used * 2)}]
            set allow_maxmemory [expr {(($allow_limit * 100) + 94) / 95}]
            $replica config set maxmemory $allow_maxmemory

            wait_for_sync $replica 300 50
            assert_equal 0 [$replica exists old-data]
            assert_equal 1 [$replica exists full-sync-memory:0]
        }
    }
}
