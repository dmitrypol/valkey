tags {external:skip cluster} {
    start_server [list overrides [list cluster-enabled yes cluster-databases 16]] {
        foreach subcommand {CCR-INFO CCR-NODES CCR-SHARDS CCR-SLOTS} {
            test "CLUSTER $subcommand reports not implemented" {
                assert_error "ERR CLUSTER $subcommand is not implemented" [list r CLUSTER $subcommand]
            }
        }

        test {CLUSTER CCR topology commands reject extra arguments} {
            foreach subcommand {CCR-INFO CCR-NODES CCR-SHARDS CCR-SLOTS} {
                assert_error {*wrong number of arguments*} [list r CLUSTER $subcommand extra]
            }
        }

        test {CLUSTER HELP documents CCR topology commands} {
            set help [r CLUSTER HELP]
            foreach subcommand {CCR-INFO CCR-NODES CCR-SHARDS CCR-SLOTS} {
                assert {[lsearch -exact $help $subcommand] != -1}
            }
        }
    }
}
