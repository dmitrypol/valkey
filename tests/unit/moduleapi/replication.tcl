set testmodule [file normalize tests/modules/replication.so]

start_server {tags {"modules repl network external:skip"}} {
    r module load $testmodule
    set replica [srv 0 client]

    start_server {} {
        set primary [srv 0 client]
        set primary_host [srv 0 host]
        set primary_port [srv 0 port]

        # Keep the replica in the handshake state while exercising the API.
        $primary config set repl-diskless-sync yes
        $primary config set repl-diskless-sync-delay 1000
        $primary config set rdb-key-save-delay 10000
        populate 1000
        $replica replicaof $primary_host $primary_port

        test {module API aborts a replication handshake without reconnecting immediately} {
            wait_for_condition 50 1000 {
                [string match *handshake* [$replica role]]
            } else {
                fail "Replica did not enter handshake state"
            }

            assert_equal {1 0} [$replica test.abort_replication_handshake]

            set role [$replica role]
            assert_equal slave [lindex $role 0]
            assert_equal $primary_host [lindex $role 1]
            assert_equal $primary_port [lindex $role 2]
            assert_equal connect [lindex $role 3]
        }

        test {module API aborts an active RDB transfer without reconnecting immediately} {
            wait_for_condition 50 100 {
                [s connected_slaves] == 0
            } else {
                fail "Primary did not observe the aborted handshake"
            }

            $primary config set repl-diskless-sync-delay 0
            wait_for_condition 100 100 {
                [string match *sync* [$replica role]]
            } else {
                fail "Replica did not enter RDB transfer state"
            }

            assert_equal {1 0} [$replica test.abort_replication_handshake]
        }
    }
}
