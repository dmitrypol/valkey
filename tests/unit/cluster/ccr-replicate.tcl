tags {external:skip cluster} {
    start_server [list overrides [list cluster-enabled yes cluster-databases 16]] {
        test {CLUSTER CCR-REPLICATE valid forms report not implemented} {
            assert_error {ERR CLUSTER CCR-REPLICATE is not implemented} {r CLUSTER CCR-REPLICATE cache.example 6379}
            assert_error {ERR CLUSTER CCR-REPLICATE is not implemented} {r cluster ccr-replicate 127.0.0.1 1}
            assert_error {ERR CLUSTER CCR-REPLICATE is not implemented} {r CLUSTER CCR-REPLICATE 2001:db8::1 65535}
            assert_error {ERR CLUSTER CCR-REPLICATE is not implemented} {r CLUSTER CCR-REPLICATE NO ONE}
            assert_error {ERR CLUSTER CCR-REPLICATE is not implemented} {r cluster ccr-replicate no one}
        }

        test {CLUSTER CCR-REPLICATE rejects malformed argument counts} {
            assert_error {*wrong number of arguments*} {r CLUSTER CCR-REPLICATE}
            assert_error {*wrong number of arguments*} {r CLUSTER CCR-REPLICATE cache.example}
            assert_error {*wrong number of arguments*} {r CLUSTER CCR-REPLICATE cache.example 6379 extra}
        }

        test {CLUSTER CCR-REPLICATE rejects invalid seed arguments} {
            assert_error {ERR Seed host must not be empty} {r CLUSTER CCR-REPLICATE {} 6379}
            foreach port {{} +6379 06379 port 0 65536} {
                assert_error {ERR Invalid seed port: expected an integer between 1 and 65535} [list r CLUSTER CCR-REPLICATE cache.example $port]
            }
            assert_error {ERR Invalid seed port: expected an integer between 1 and 65535} {r CLUSTER CCR-REPLICATE NO TWO}
            assert_error {ERR Invalid seed port: expected an integer between 1 and 65535} {r CLUSTER CCR-REPLICATE YES ONE}
        }

        test {Removed promotion command name is unavailable} {
            assert_error {*unknown subcommand*} {r CLUSTER PROMOTE}
        }

        test {CLUSTER HELP documents only the node-local CCR-REPLICATE scaffold} {
            set help [r CLUSTER HELP]
            assert {[lsearch -exact $help {CCR-REPLICATE <seed-host> <seed-port>}] != -1}
            assert {[lsearch -exact $help {CCR-REPLICATE NO ONE}] != -1}
            assert {[lsearch -exact $help {PROMOTE}] == -1}

            set docs [dict create {*}[lindex [r COMMAND DOCS cluster|ccr-replicate] 1]]
            set args [dict create {*}[lindex [dict get $docs arguments] 0]]
            set forms [dict get $args arguments]
            set host_port [dict create {*}[lindex $forms 0]]
            set host_port_args [dict get $host_port arguments]
            assert_equal {seed-host} [dict get [dict create {*}[lindex $host_port_args 0]] display_text]
            assert_equal {seed-port} [dict get [dict create {*}[lindex $host_port_args 1]] display_text]
        }
    }
}
