set testmodule [file normalize tests/modules/hellooptions_test.so]

start_server {tags {modules}} {
    r module load $testmodule

    test {HELLOOPTIONS.GET returns a string value} {
        r set example-key example-value
        r hellooptions.get example-key
    } {example-value}

    test {HELLOOPTIONS.GET exposes its registered options} {
        set info [lindex [r command info hellooptions.get] 0]
        assert_equal {fast module readonly} [lsort [lindex $info 2]]
        assert_equal {@fast @read} [lsort [lindex $info 6]]
        assert_equal {example-key} [r command getkeys hellooptions.get example-key]

        set docs [dict create {*}[lindex [r command docs hellooptions.get] 1]]
        assert_equal {Returns the string value stored at a key.} [dict get $docs summary]
    }

    test {Unload the hellooptions example module} {
        r module unload hellooptions
    } {OK}
}
