# Form a cluster from just the listed nodes. Each primary owns its given slot
# range, and the optional replica follows the first primary.
proc setup_shardreplicate_cluster {ranges {replica {}}} {
    set first [lindex $ranges 0 0]
    set nodes {}
    foreach range $ranges {
        lassign $range id start end
        lappend nodes $id
        R $id cluster addslotsrange $start $end
    }
    if {$replica ne {}} {lappend nodes $replica}
    foreach id $nodes {
        R $id cluster set-config-epoch [expr {$id + 1}]
        if {$id != $first} {
            R $first cluster meet [srv -$id host] [srv -$id port]
        }
    }
    if {$replica ne {}} {
        set primary [R $first cluster myid]
        wait_for_condition 100 50 {
            [cluster_get_node_by_id $replica $primary] ne {}
        } else {
            fail "Replica did not discover its primary"
        }
        R $replica cluster replicate $primary
        wait_for_sync [Rn $replica]
        R $replica readonly
    }
    foreach id $nodes {
        wait_for_condition 100 50 {
            [CI $id cluster_state] eq "ok" &&
            [CI $id cluster_size] == [llength $ranges]
        } else {
            fail "Cluster did not converge on node $id"
        }
    }
}

set options {tags {cluster singledb external:skip} overrides {
    cluster-enabled yes cluster-ping-interval 100 repl-diskless-sync-delay 0
}}

start_multiple_servers 6 $options {
    setup_shardreplicate_cluster {{0 0 8191} {1 8192 16383}} 2
    setup_shardreplicate_cluster {{3 0 8191} {4 8192 16383}} 5

    test "SHARDREPLICATE rejects unsafe attachments before replacing local data" {
        R 0 set bar original
        assert_error {*SETWRITEMODE READONLY*} {
            R 0 cluster shardreplicate [srv -3 host] [srv -3 port]
        }
        R 1 cluster setwritemode readonly
        wait_for_condition 100 50 {[CI 0 cluster_write_mode] eq "readonly"} else {
            fail "Destination did not receive the peer's read-only mode"
        }
        foreach source {0 1 4 5} {
            # Self, same-cluster peer, wrong slot owner, and source replica.
            assert_error {ERR *} {
                R 0 cluster shardreplicate [srv -$source host] [srv -$source port]
            }
            assert_equal original [R 0 get bar]
        }
        assert_error {ERR *} {R 2 cluster shardreplicate [srv -3 host] [srv -3 port]}
        R 0 cluster setwritemode readwrite
    }

    test "Disconnecting the requester cancels an unaccepted shard attachment" {
        R 0 set bar original
        R 0 cluster setwritemode readonly
        set rd [valkey_deferring_client]
        $rd client id
        set id [$rd read]
        R 3 client pause 10000 all
        $rd cluster shardreplicate [srv -3 host] [srv -3 port]
        wait_for_blocked_clients_count 1
        assert_equal 1 [R 0 client kill id $id]
        $rd close
        R 3 client unpause
        assert_equal OK [R 0 cluster setwritemode readwrite]
        assert_equal original [R 0 get bar]
    }

    test "SHARDREPLICATE NO ONE cancels a pending attachment without replacing local data" {
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        assert_error {ERR *} {R 2 cluster shardreplicate NO ONE}
        R 0 set {pending{bar}} original
        wait_for_value_to_propagate_to_replica [Rn 0] [Rn 2] {pending{bar}}
        set replid [s 0 master_replid]
        set replica_id [get_field_in_client_info [R 0 client list type replica] id]
        R 0 cluster setwritemode readonly
        set rd [valkey_deferring_client]
        pause_process [srv -3 pid]
        $rd cluster shardreplicate [srv -3 host] [srv -3 port]
        wait_for_blocked_clients_count 1
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        resume_process [srv -3 pid]
        assert_error {ERR *} {$rd read}
        $rd close
        assert_equal $replid [s 0 master_replid]
        assert_equal $replica_id [get_field_in_client_info [R 0 client list type replica] id]
        assert_equal original [R 0 get {pending{bar}}]
        assert_error {READONLY *} {R 0 set {pending{bar}} rejected}
        R 0 cluster setwritemode readwrite
    }

    test "SHARDREPLICATE NO ONE cancels an accepted transfer before loading its snapshot" {
        # A disk-backed snapshot cannot be delivered until the child finishes.
        test_config_set {R 3} repl-diskless-sync no
        test_config_set {R 3} rdb-key-save-delay 1000000
        R 3 mset {first{bar}} remote {second{bar}} remote
        R 0 set {first{bar}} local
        wait_for_value_to_propagate_to_replica [Rn 0] [Rn 2] {first{bar}}
        set replid [s 0 master_replid]
        set replica_id [get_field_in_client_info [R 0 client list type replica] id]
        R 0 cluster setwritemode readonly
        assert_equal OK [R 0 cluster shardreplicate [srv -3 host] [srv -3 port]]
        assert_equal 1 [s -3 rdb_bgsave_in_progress]
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        wait_for_condition 200 50 {![s -3 rdb_bgsave_in_progress]} else {
            fail "Source did not finish its canceled snapshot"
        }
        assert_equal local [R 0 get {first{bar}}]
        assert_equal local [R 2 get {first{bar}}]
        assert_equal $replid [s 0 master_replid]
        assert_equal $replica_id [get_field_in_client_info [R 0 client list type replica] id]
        R 0 cluster setwritemode readwrite
    }

    test "SHARDREPLICATE NO ONE preserves local replicas and read-only mode across restart" {
        set slots [R 0 cluster slots]
        R 3 set {detach{bar}} original
        wait_for_condition 100 50 {[CI 1 cluster_write_mode_version] eq [CI 0 cluster_write_mode_version]} else {
            fail "Destination primaries did not converge before the mode change"
        }
        R 1 cluster setwritemode readonly
        set version [CI 1 cluster_write_mode_version]
        wait_for_condition 100 50 {[CI 0 cluster_write_mode_version] eq $version} else {
            fail "Destination did not receive the cluster-wide read-only mode"
        }
        assert_equal OK [R 0 cluster shardreplicate [srv -3 host] [srv -3 port]]
        wait_for_value_to_propagate_to_replica [Rn 3] [Rn 2] {detach{bar}}
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        assert_equal $version [CI 0 cluster_write_mode_version]
        R 3 set {detach{bar}} changed
        wait_for_value_to_propagate_to_replica [Rn 3] [Rn 5] {detach{bar}}
        wait_for_condition 100 50 {![string match {*type=shard-replica*} [R 3 info replication]]} else {
            fail "Source still reports a detached receiver"
        }
        wait_for_condition 100 50 {
            [s -2 master_link_status] eq "up" && [R 0 cluster slots] eq $slots
        } else {
            fail "Local replica did not reconnect to the original shard"
        }
        assert_equal master [lindex [R 0 role] 0]
        assert_equal original [R 0 get {detach{bar}}]
        assert_equal original [R 2 get {detach{bar}}]
        assert_error {READONLY *} {R 0 set {detach{bar}} rejected}
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        R 0 save
        restart_server 0 true false
        wait_for_cluster_state ok
        assert_equal readonly [CI 0 cluster_write_mode]
        assert_equal original [R 0 get {detach{bar}}]
        R 1 cluster setwritemode readwrite
        set version [CI 1 cluster_write_mode_version]
        wait_for_condition 100 50 {[CI 0 cluster_write_mode_version] eq $version} else {
            fail "Detached primary did not receive the peer's read-write mode"
        }
        R 0 set {local{bar}} independent
        wait_for_value_to_propagate_to_replica [Rn 0] [Rn 2] {local{bar}}

        # Reattachment must replace the locally divergent dataset.
        R 0 cluster setwritemode readonly
        assert_equal OK [R 0 cluster shardreplicate [srv -3 host] [srv -3 port]]
        wait_for_value_to_propagate_to_replica [Rn 3] [Rn 2] {detach{bar}}
        assert_equal 0 [R 0 exists {local{bar}}]
        assert_equal 0 [R 2 exists {local{bar}}]
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        R 0 cluster setwritemode readwrite
    }

    test "SHARDREPLICATE serves the source snapshot and later writes on the destination shard" {
        R 3 set {before{bar}} snapshot
        R 4 set foo other-shard
        R 0 set bar stale
        wait_for_value_to_propagate_to_replica [Rn 0] [Rn 2] bar
        R 0 cluster setwritemode readonly
        assert_equal OK [R 0 cluster shardreplicate [srv -3 host] [srv -3 port]]
        wait_for_condition 200 50 {
            [replica_value_matches_or_is_loading [Rn 0] {before{bar}} snapshot] &&
            [replica_value_matches_or_is_loading [Rn 2] {before{bar}} snapshot]
        } else {
            fail "Snapshot did not reach both members of the destination shard"
        }
        assert_equal up [s 0 shard_source_link_status]
        assert_equal [srv -3 port] [s 0 shard_source_port]
        assert_match {*type=shard-replica*} [R 3 info replication]
        assert_equal 0 [R 0 exists bar]
        assert_equal 0 [R 2 exists bar]
        assert_equal {} [R 1 get foo]
        foreach primary {0 3} replica {2 5} {
            assert_equal master [lindex [R $primary role] 0]
            assert_equal master [s -$primary role]
            assert_equal slave [lindex [R $replica role] 0]
            assert_equal [srv -$primary port] [lindex [R $replica role] 2]
            assert_equal [R $primary cluster myid] [dict get [cluster_get_myself $replica] slaveof]
            assert_equal 3 [CI $primary cluster_known_nodes]
            assert_equal 2 [CI $primary cluster_size]
        }
        assert_error {READONLY *} {R 0 set bar rejected}
        set version [CI 0 cluster_write_mode_version]
        wait_for_condition 100 50 {
            [CI 1 cluster_write_mode_version] eq $version && [CI 2 cluster_write_mode_version] eq $version
        } else {
            fail "Destination cluster did not converge on the requested read-only mode"
        }
        R 1 cluster setwritemode readwrite
        set version [CI 1 cluster_write_mode_version]
        wait_for_condition 100 50 {
            [CI 0 cluster_write_mode_version] eq $version && [CI 0 cluster_write_mode] eq "readwrite"
        } else {
            fail "Peer's read-write request did not propagate"
        }
        # The attachment itself must fence writes regardless of the ordinary replica setting.
        test_config_set {R 0} replica-read-only no
        assert_error {READONLY *} {R 0 set bar rejected}
        R 3 multi
        R 3 del {before{bar}}
        R 3 rpush bar one two
        assert_equal {1 2} [R 3 exec]
        # WAIT must count the source shard's local replica only.
        assert_equal 1 [R 3 wait 1 5000]
        assert_equal 1 [R 3 wait 2 100]
        assert_equal 1 [llength [lindex [R 3 role] 2]]
        wait_for_condition 200 50 {
            [R 0 lrange bar 0 -1] eq {one two} && [R 2 lrange bar 0 -1] eq {one two} &&
            [R 5 lrange bar 0 -1] eq {one two}
        } else {
            fail "Incremental updates did not reach the destination primary and both local replicas"
        }
        assert_equal 0 [R 0 exists {before{bar}}]
        # A source topology command waits only for its own shard's replicas.
        assert_equal OK [R 3 cluster setslot 0 stable timeout 5000]
        assert_equal OK [R 0 cluster shardreplicate NO ONE]
        assert_equal $version [CI 0 cluster_write_mode_version]
        assert_equal OK [R 0 set bar independent]
    }
}

start_multiple_servers 5 $options {
    setup_shardreplicate_cluster {{0 0 8191} {1 8192 16383}}
    setup_shardreplicate_cluster {{2 0 8191} {3 8192 12000} {4 12001 16383}}

    test "SHARDREPLICATE rejects unequal shard counts even when the endpoint owns identical slots" {
        R 0 set bar preserved
        R 2 set bar foreign
        R 0 cluster setwritemode readonly
        assert_error {*source topology*} {R 0 cluster shardreplicate [srv -2 host] [srv -2 port]}
        assert_equal preserved [R 0 get bar]
    }
}

# Both single-shard primaries own every slot, but a snapshot must also fit
# the destination's configured database range.
set source_options $options
dict lappend source_options overrides cluster-databases 2
set destination_options $options
dict lappend destination_options overrides cluster-databases 1
start_server $source_options {
    start_server $destination_options {
        setup_shardreplicate_cluster {{0 0 16383}}
        setup_shardreplicate_cluster {{1 0 16383}}
        test "SHARDREPLICATE rejects incompatible database counts before full sync" {
            R 0 set bar preserved
            R 0 cluster setwritemode readonly
            assert_error {*source topology*} {R 0 cluster shardreplicate [srv -1 host] [srv -1 port]}
            assert_equal preserved [R 0 get bar]
        }
    }
}
