start_cluster 1 0 {tags {external:skip cluster}} {
    test "A cluster primary keeps serving all slots in READONLY mode" {
        assert_equal 16384 [CI 0 cluster_slots_assigned]
        assert_equal OK [R 0 set key before]
        set slots [R 0 cluster slots]
        assert_equal OK [R 0 cluster setwritemode "ReadOnly\x00ignored"]
        foreach invalid [list "" READWRIT READWRITEX "READ\x00RITE"] {
            assert_error {ERR syntax error} {R 0 cluster setwritemode $invalid}
        }
        assert_error {READONLY *} {R 0 set key rejected}
        assert_equal before [R 0 get key]
        assert_equal $slots [R 0 cluster slots]
        assert_equal OK [R 0 cluster setwritemode "ReadWrite\x00"]
        assert_equal OK [R 0 set key after]
        assert_equal after [R 0 get key]
    }

    test "A read-only write under memory pressure rejects before evicting keys" {
        R 0 rpush resident original
        R 0 cluster setwritemode readonly
        test_defer {R 0 cluster setwritemode readwrite}
        test_config_set {R 0} maxmemory-policy allkeys-random

        # Small arguments put the request over maxmemory without leaving a large client input buffer.
        test_config_set {R 0} maxmemory [expr {[s used_memory] + 1024 * 1024}]
        set values [lrepeat 512 [string repeat x 8192]]
        assert_error {READONLY *} {R 0 rpush resident {*}$values}
        assert_equal {original} [R 0 lrange resident 0 -1]
    }

    test "Detailed cluster reports show the local write mode below cluster_state" {
        assert_equal readwrite [CI 0 cluster_write_mode]
        set version [CI 0 cluster_write_mode_version]
        R 0 cluster setwritemode readonly
        foreach cmd {{cluster info} {info cluster_info} {info all}} {
            assert_match "*cluster_state:ok\r\ncluster_write_mode:readonly\r\ncluster_write_mode_version:[expr {$version + 3}]\r\n*" [R 0 {*}$cmd]
        }
        assert_no_match {*cluster_write_mode*} [R 0 info cluster]
        assert_no_match {*cluster_write_mode*} [R 0 info]
        R 0 cluster setwritemode readwrite
        assert_equal readwrite [CI 0 cluster_write_mode]
        assert_equal [expr {$version + 4}] [CI 0 cluster_write_mode_version]
    }

    test "Read-only mode fences transactions and scripts" {
        R 0 set key original
        R 0 function load {#!lua name=policy
            redis.register_function('store', function(keys, args)
                return redis.call('set', keys[1], 'function')
            end)
        }
        set tx [valkey_client]
        $tx multi
        assert_equal QUEUED [$tx set key queued]
        R 0 cluster setwritemode readonly
        assert_error {EXECABORT *READONLY *} {$tx exec}
        $tx close

        assert_error {ERR syntax error} {R 0 cluster setwritemode invalid}
        assert_error {READONLY *} {R 0 flushall}
        assert_error {*READONLY*} {R 0 eval {return redis.call('set', KEYS[1], 'script')} 1 key}
        assert_error {READONLY *} {R 0 fcall store 1 key}
        assert_equal original [R 0 eval {return redis.call('get', KEYS[1])} 1 key]
        assert_equal OK [R 0 multi]
        assert_equal QUEUED [R 0 get key]
        assert_equal original [R 0 exec]
        assert_equal OK [R 0 cluster setwritemode readwrite]
    }

    test "A single-node cluster remembers READONLY after restart" {
        R 0 cluster setwritemode readonly
        restart_server 0 true false
        wait_for_cluster_state ok
        assert_error {READONLY *} {R 0 set key rejected}
        assert_equal OK [R 0 cluster setwritemode readwrite]
    }
}

start_cluster 2 0 {tags {external:skip cluster}} {
    test "Changing write mode on either primary reaches both slot owners" {
        # The default allocator puts bar (slot 5061) on R0 and foo (slot 12182) on R1.
        assert_equal 0 [CI 0 cluster_write_mode_version]
        assert_equal OK [R 0 set bar original]
        assert_equal OK [R 1 set foo original]
        assert_equal OK [R 0 cluster setwritemode readonly]
        wait_for_condition 100 50 {
            [CI 1 cluster_write_mode] eq "readonly"
        } else {
            fail "Second primary did not enter read-only mode"
        }
        assert_error {READONLY *} {R 0 set bar rejected}
        assert_error {READONLY *} {R 1 set foo rejected}
        assert_equal original [R 0 get bar]
        assert_equal original [R 1 get foo]
        assert_equal 3 [CI 1 cluster_write_mode_version]

        assert_equal OK [R 1 cluster setwritemode readwrite]
        assert_equal OK [R 1 set foo changed]
        wait_for_condition 100 50 {
            [CI 0 cluster_write_mode] eq "readwrite"
        } else {
            fail "First primary did not return to read-write mode"
        }
        assert_equal OK [R 0 set bar changed]
        assert_equal changed [R 0 get bar]
        assert_equal 4 [CI 0 cluster_write_mode_version]
    }
}
