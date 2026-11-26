tags {external:skip cluster} {
    start_server [list overrides [list cluster-enabled yes cluster-databases 16]] {
        test {CLUSTER CCR-INFO reports not implemented} {
            assert_error "ERR CLUSTER CCR-INFO is not implemented" {r CLUSTER CCR-INFO}
        }

        test {CLUSTER CCR-INFO rejects extra arguments} {
            assert_error {*wrong number of arguments*} {r CLUSTER CCR-INFO extra}
        }

        test {CLUSTER HELP documents CCR-INFO} {
            set help [r CLUSTER HELP]
            assert {[lsearch -exact $help CCR-INFO] != -1}
            foreach subcommand {CCR-NODES CCR-SHARDS CCR-SLOTS} {
                assert {[lsearch -exact $help $subcommand] == -1}
            }
        }
    }
}
