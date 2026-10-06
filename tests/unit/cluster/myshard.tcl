tags {external:skip cluster} {
    start_server [list overrides [list cluster-enabled yes cluster-databases 16]] {
        test {CLUSTER MYSHARD reports not implemented} {
            assert_error {ERR CLUSTER MYSHARD is not implemented} {r CLUSTER MYSHARD}
        }

        test {CLUSTER MYSHARD rejects extra arguments} {
            assert_error {*wrong number of arguments*} {r CLUSTER MYSHARD extra}
        }

        test {CLUSTER HELP documents MYSHARD} {
            assert {[lsearch -exact [r CLUSTER HELP] MYSHARD] != -1}
        }
    }
}
