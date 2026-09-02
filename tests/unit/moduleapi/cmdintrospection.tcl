set testmodule [file normalize tests/modules/cmdintrospection.so]

start_server {tags {"modules"}} {
    r module load $testmodule

    # cmdintrospection.xadd mimics XADD with regards to how
    # what COMMAND exposes. There are two differences:
    #
    # 1. cmdintrospection.xadd (and all module commands) do not have ACL categories
    # 2. cmdintrospection.xadd's `group` is "module"
    #
    # This tests verify that, apart from the above differences, the output of
    # COMMAND INFO and COMMAND DOCS are identical for the two commands.
    test "Module command introspection via COMMAND INFO" {
        set redis_reply [lindex [r command info xadd] 0]
        set module_reply [lindex [r command info cmdintrospection.xadd] 0]
        for {set i 1} {$i < [llength $redis_reply]} {incr i} {
            if {$i == 2} {
                # Remove the "module" flag
                set mylist [lindex $module_reply $i]
                set idx [lsearch $mylist "module"]
                set mylist [lreplace $mylist $idx $idx]
                lset module_reply $i $mylist
            }
            if {$i == 6} {
                # Skip ACL categories
                continue
            }
            assert_equal [lindex $redis_reply $i] [lindex $module_reply $i]
        }
    }

    test "Module command introspection via COMMAND DOCS" {
        set redis_reply [dict create {*}[lindex [r command docs xadd] 1]]
        set module_reply [dict create {*}[lindex [r command docs cmdintrospection.xadd] 1]]
        # Compare the maps. We need to pop "group" first.
        dict unset redis_reply group
        dict unset module_reply group
        dict unset module_reply module
        if {$::log_req_res} {
            dict unset redis_reply reply_schema
        }

        assert_equal $redis_reply $module_reply
    }

    test "Module command registration with options" {
        set info [lindex [r command info cmdintrospection.options] 0]
        assert_equal {-1} [lindex $info 1]
        assert_equal {denyoom module write} [lsort [lindex $info 2]]
        assert_equal {@write} [lindex $info 6]
        assert_equal {key} [r command getkeys cmdintrospection.options key]

        set docs [dict create {*}[lindex [r command docs cmdintrospection.options] 1]]
        assert_equal {Tests command registration with options.} [dict get $docs summary]
    }

    test "Unload the module - cmdintrospection" {
        assert_equal {OK} [r module unload cmdintrospection]
    }
}
