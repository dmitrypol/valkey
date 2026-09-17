tags {external:skip cluster} {
    start_server [list overrides [list cluster-enabled yes cluster-databases 16]] {
        test {CLUSTER SET-WRITE-MODE valid modes report not implemented} {
            assert_error {ERR CLUSTER SET-WRITE-MODE is not implemented} {r CLUSTER SET-WRITE-MODE READONLY}
            assert_error {ERR CLUSTER SET-WRITE-MODE is not implemented} {r cluster set-write-mode readwrite}
        }

        test {CLUSTER SET-WRITE-MODE rejects invalid modes} {
            assert_error {ERR Invalid write mode: expected READONLY or READWRITE} {r CLUSTER SET-WRITE-MODE readonlyy}
        }

        test {CLUSTER SET-WRITE-MODE rejects malformed argument counts} {
            assert_error {*wrong number of arguments*} {r CLUSTER SET-WRITE-MODE}
            assert_error {*wrong number of arguments*} {r CLUSTER SET-WRITE-MODE READONLY extra}
        }

        test {CLUSTER HELP documents SET-WRITE-MODE} {
            set help [r CLUSTER HELP]
            assert {[lsearch -exact $help {SET-WRITE-MODE <READONLY | READWRITE>}] != -1}
        }
    }
}
