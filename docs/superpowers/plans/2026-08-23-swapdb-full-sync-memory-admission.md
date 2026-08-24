# Swapdb Full-Sync Memory Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent swapdb diskless full synchronization from starting when the primary's conservative memory estimate exceeds the replica's configured remaining memory budget.

**Architecture:** An opt-in replica configuration converts a percentage of `maxmemory` into an additional-allocation budget immediately before PSYNC. The replica sends that budget through a required REPLCONF handshake extension; after partial synchronization fails, a supporting primary rejects the full sync before BGSAVE bookkeeping or startup when its current allocator usage exceeds the budget.

**Tech Stack:** Valkey C server, replication protocol, generated JSON command metadata, Tcl integration tests.

**Spec:** `docs/superpowers/specs/2026-08-23-swapdb-full-sync-memory-admission-design.md`

## Global Constraints

- Keep the feature disabled by default with `repl-diskless-load-swapdb-max-memory-percent 0`.
- Apply admission only when `repl-diskless-load swapdb` is active.
- Measure the replica against configured `maxmemory`, not RSS, host memory, or cgroup memory.
- Treat enabled admission with `maxmemory 0` as a zero budget and fail closed for full sync.
- Attempt partial synchronization before applying the full-sync budget.
- Reject before `stat_sync_full++`, replica-list insertion, backlog creation, BGSAVE attachment, or BGSAVE startup.
- Never fall back to legacy `SYNC` after a memory rejection or unsupported budget handshake.
- Preserve old replica data and use normal replication reconnects to re-evaluate memory.
- Keep changes minimal and avoid unrelated replication refactors.
- Do not create Git commits while executing this plan unless the user explicitly authorizes commits later.

---

### Task 1: Add configuration and overflow-safe replica budget calculation

**Files:**
- Modify: `src/server.h` (replica configuration fields and helper declaration)
- Modify: `src/config.c` (configuration registration)
- Modify: `valkey.conf` (operator documentation)
- Create: `tests/integration/replication-full-sync-memory.tcl`

**Interfaces:**
- Produces: `int server.repl_diskless_load_swapdb_max_memory_percent`
- Produces: `int replicaFullSyncMemoryBudget(unsigned long long *budget, unsigned long long *used, unsigned long long *limit)`; returns `1` only when the guard is active and fills all outputs.
- Consumes: `server.repl_diskless_load`, `server.maxmemory`, `zmalloc_used_memory()`, and `freeMemoryGetNotCountedMemory()`.

- [ ] **Step 1: Write failing configuration tests**

Add the first test block to `tests/integration/replication-full-sync-memory.tcl`:

```tcl
start_server {tags {repl needs:config-maxmemory} overrides {save ""}} {
    test {swapdb full-sync memory admission percentage validates and round-trips} {
        assert_equal 0 [lindex [r config get repl-diskless-load-swapdb-max-memory-percent] 1]
        assert_equal OK [r config set repl-diskless-load-swapdb-max-memory-percent 95]
        assert_equal 95 [lindex [r config get repl-diskless-load-swapdb-max-memory-percent] 1]
        assert_equal OK [r config set repl-diskless-load-swapdb-max-memory-percent 100]
        assert_error {*argument must be between 0 and 100*} {
            r config set repl-diskless-load-swapdb-max-memory-percent 101
        }
        assert_error {*argument must be between 0 and 100*} {
            r config set repl-diskless-load-swapdb-max-memory-percent -1
        }
    }
}
```

- [ ] **Step 2: Run the focused test and confirm the missing-config failure**

Run:

```bash
./runtest --single tests/integration/replication-full-sync-memory.tcl
```

Expected: FAIL because `repl-diskless-load-swapdb-max-memory-percent` is unknown.

- [ ] **Step 3: Register the configuration and server field**

Add near `repl_diskless_load` in `struct valkeyServer`:

```c
int repl_diskless_load_swapdb_max_memory_percent; /* Full-sync admission threshold as percent of maxmemory. */
```

Register it with the other replication integer configs in `src/config.c`:

```c
createIntConfig("repl-diskless-load-swapdb-max-memory-percent", NULL,
                MODIFIABLE_CONFIG | DENY_LOADING_CONFIG, 0, 100,
                server.repl_diskless_load_swapdb_max_memory_percent, 0,
                INTEGER_CONFIG, NULL, NULL),
```

Do not add manual initialization; the configuration registration supplies the default.

- [ ] **Step 4: Implement the budget helper next to replica handshake helpers**

Declare in `src/server.h` and implement in `src/replication.c`:

```c
int replicaFullSyncMemoryBudget(unsigned long long *budget,
                                unsigned long long *used,
                                unsigned long long *limit) {
    int percent = server.repl_diskless_load_swapdb_max_memory_percent;
    if (server.repl_diskless_load != REPL_DISKLESS_LOAD_SWAPDB || percent == 0) return 0;

    size_t allocated = zmalloc_used_memory();
    size_t not_counted = freeMemoryGetNotCountedMemory();
    if (not_counted > allocated) not_counted = allocated;
    *used = allocated - not_counted;

    *limit = (server.maxmemory / 100) * percent;
    *limit += ((server.maxmemory % 100) * percent) / 100;
    *budget = *used >= *limit ? 0 : *limit - *used;
    return 1;
}
```

Keep all arithmetic unsigned and preserve the quotient/remainder form so `maxmemory * percent` cannot overflow.

- [ ] **Step 5: Document the setting in `valkey.conf`**

Immediately after the `repl-diskless-load` explanation, add:

```text
# When repl-diskless-load is set to swapdb, a full synchronization can keep
# both the old and incoming datasets in memory. A non-zero percentage makes
# the replica advertise only the memory remaining below that percentage of
# maxmemory as its full-sync budget. The primary rejects a full sync before
# starting it when its current memory estimate exceeds the budget. Partial
# synchronization is still allowed. A value of 0 disables this check. If this
# is enabled while maxmemory is 0, full synchronization is rejected.
repl-diskless-load-swapdb-max-memory-percent 0
```

- [ ] **Step 6: Run the configuration test and whitespace validation**

Run:

```bash
./runtest --single tests/integration/replication-full-sync-memory.tcl
git diff --check
```

Expected: the configuration test passes and `git diff --check` exits zero.

- [ ] **Step 7: Leave Task 1 changes uncommitted**

Run `git status --short` and confirm only intended files are modified. Do not run `git commit`.

---

### Task 2: Negotiate and store the replica's full-sync memory budget

**Files:**
- Modify: `src/server.h` (handshake state and per-client replication fields)
- Modify: `src/replication.c` (REPLCONF parsing, send/receive handshake, cleanup)
- Modify: `tests/integration/replication-full-sync-memory.tcl`

**Interfaces:**
- Consumes: `replicaFullSyncMemoryBudget(...)` from Task 1.
- Produces: `unsigned long long client.repl_data->full_sync_memory_budget` and `int client.repl_data->full_sync_memory_budget_set` on the primary-side replica connection.
- Produces: handshake command `REPLCONF full-sync-memory-budget <unsigned-bytes>`.
- Produces: `syncWithPrimaryHandleReceiveFullSyncMemoryBudgetReplyState(connection *conn)` returning `C_OK` only for a positive reply.

- [ ] **Step 1: Add a failing direct REPLCONF protocol test**

Append to the focused test file:

```tcl
start_server {tags {repl}} {
    test {REPLCONF accepts a full-sync memory budget} {
        assert_equal OK [r replconf full-sync-memory-budget 12345]
    }

    test {REPLCONF rejects invalid full-sync memory budgets} {
        assert_error {*invalid full-sync memory budget*} {
            r replconf full-sync-memory-budget -1
        }
        assert_error {*invalid full-sync memory budget*} {
            r replconf full-sync-memory-budget not-a-number
        }
    }
}
```

- [ ] **Step 2: Run the focused test and confirm REPLCONF rejects the new option**

Run `./runtest --single tests/integration/replication-full-sync-memory.tcl`.

Expected: FAIL because the REPLCONF option is not implemented.

- [ ] **Step 3: Add per-connection fields and parse REPLCONF**

Add to the client replication-data structure in `src/server.h`:

```c
unsigned long long full_sync_memory_budget;
int full_sync_memory_budget_set;
```

Initialize both to zero in `initClientReplicationData()`.

In `replconfCommand()`, parse the complete unsigned range with the existing `string2ull()` utility:

```c
} else if (!strcasecmp(objectGetVal(c->argv[j]), "full-sync-memory-budget")) {
    unsigned long long budget;
    sds value = objectGetVal(c->argv[j + 1]);
    if (!string2ull(value, sdslen(value), &budget)) {
        addReplyError(c, "invalid full-sync memory budget");
        return;
    }
    c->repl_data->full_sync_memory_budget = budget;
    c->repl_data->full_sync_memory_budget_set = 1;
```

- [ ] **Step 4: Add an optional critical handshake exchange**

Extend the replica handshake enum with `REPL_STATE_RECEIVE_FULLSYNC_MEMORY_BUDGET_REPLY` immediately before `REPL_STATE_SEND_PSYNC`. Ensure `replicaIsInHandshakeState()` still includes it.

In `syncWithPrimaryHandleSendHandshakeState()`, after existing best-effort REPLCONF commands, calculate and send the budget when active:

```c
unsigned long long budget, used, limit;
if (replicaFullSyncMemoryBudget(&budget, &used, &limit)) {
    char budgetstr[LONG_STR_SIZE];
    ull2string(budgetstr, sizeof(budgetstr), budget);
    err = sendCommand(conn, "REPLCONF", "full-sync-memory-budget", budgetstr, NULL);
    if (err) goto err;
}
```

Store `used`, `limit`, and `budget` in replica server fields for rejection logging, or recompute local values when processing the rejection. Do not send this REPLCONF when the guard is inactive.

After the existing optional handshake replies are consumed, transition to `REPL_STATE_RECEIVE_FULLSYNC_MEMORY_BUDGET_REPLY` only when the guard is active. Its receive handler must treat a negative reply as critical:

```c
if (err[0] == '-') {
    serverLog(LL_WARNING,
              "Primary does not support swapdb full-sync memory admission: %s", err);
    sdsfree(err);
    return C_ERR;
}
```

This failure must call `syncWithPrimaryHandleError()` and return to `REPL_STATE_CONNECT` without sending PSYNC.

- [ ] **Step 5: Test that inactive modes omit the strict handshake**

Add cases proving that percentage `0` and `repl-diskless-load disabled` complete full synchronization normally. Use `wait_for_sync` and assert the primary's `sync_full` increases.

- [ ] **Step 6: Run the focused tests**

Run `./runtest --single tests/integration/replication-full-sync-memory.tcl`.

Expected: direct REPLCONF validation and inactive-mode compatibility cases pass.

- [ ] **Step 7: Leave Task 2 changes uncommitted**

Run `git status --short` and confirm only intended files are modified. Do not run `git commit`.

---

### Task 3: Reject unsafe full syncs before BGSAVE and retry safely

**Files:**
- Modify: `src/server.h` (statistic field and PSYNC result constant dependencies)
- Modify: `src/server.c` (stat initialization and INFO output)
- Modify: `src/replication.c` (primary admission and replica rejection handling)
- Modify: `tests/integration/replication-full-sync-memory.tcl`

**Interfaces:**
- Consumes: primary-side `full_sync_memory_budget` fields from Task 2.
- Produces: PSYNC error prefix `-FULLSYNCMEMORY`.
- Produces: `long long server.stat_sync_full_rejected_memory` exposed as `sync_full_rejected_memory` in `INFO stats`.
- Produces: `PSYNC_FULLRESYNC_MEMORY_REJECTED` result, handled as retryable without legacy SYNC fallback.

- [ ] **Step 1: Write the failing rejection-and-recovery test**

Add a two-server block that:

1. Configures the replica with `repl-diskless-load swapdb`, percentage `95`, and an initial dataset key such as `old-data`.
2. Populates the primary until its `used_memory` is comfortably larger than the replica's computed budget.
3. Sets replica `maxmemory` so `floor(maxmemory * 95 / 100) - replica_used_memory < primary_used_memory`.
4. Runs `REPLICAOF` and waits for `sync_full_rejected_memory` to increase.
5. Asserts primary `sync_full` did not increase, the replica remains a replica with a down link, and `old-data` remains readable.
6. Raises replica `maxmemory` enough that the budget exceeds a fresh primary `used_memory` sample.
7. Waits for the automatic retry to complete and asserts the primary dataset replaced the old dataset.

Use integer Tcl arithmetic and at least 10 percent extra headroom in the recovery value to avoid allocator-noise flakes:

```tcl
set primary_used [status $primary used_memory]
set replica_used [status $replica used_memory]
set reject_limit [expr {$replica_used + $primary_used - 1024}]
set reject_maxmemory [expr {(($reject_limit * 100) + 94) / 95}]
$replica config set maxmemory $reject_maxmemory

set allow_limit [expr {$replica_used + ($primary_used * 12 / 10)}]
set allow_maxmemory [expr {(($allow_limit * 100) + 94) / 95}]
```

Re-sample both values immediately before setting each limit where practical.

- [ ] **Step 2: Run the focused test and confirm a full sync starts unexpectedly**

Run `./runtest --single tests/integration/replication-full-sync-memory.tcl`.

Expected: FAIL because `sync_full_rejected_memory` is missing and the primary starts full synchronization.

- [ ] **Step 3: Add primary-side admission before full-sync bookkeeping**

In `syncCommand()`, after `primaryTryPartialResynchronization()` fails but before dual-channel selection and the `/* Full resynchronization. */` block, evaluate:

```c
if (c->repl_data->full_sync_memory_budget_set) {
    unsigned long long estimate = zmalloc_used_memory();
    unsigned long long budget = c->repl_data->full_sync_memory_budget;
    if (estimate > budget) {
        server.stat_sync_full_rejected_memory++;
        serverLog(LL_NOTICE,
                  "Rejecting full synchronization for replica %s: primary memory estimate %llu exceeds budget %llu",
                  replicationGetReplicaName(c), estimate, budget);
        addReplyErrorFormat(c,
                            "FULLSYNCMEMORY primary memory estimate %llu exceeds replica full-sync budget %llu",
                            estimate, budget);
        return;
    }
}
```

Confirm by inspection that this return precedes:

- `server.stat_sync_full++`
- `c->flag.replica = 1`
- `listAddNodeTail(server.replicas, c)`
- backlog creation
- all existing-BGSAVE attachment paths
- `startBgsaveForReplication(...)`

- [ ] **Step 4: Treat memory rejection as retryable on the replica**

Add `PSYNC_FULLRESYNC_MEMORY_REJECTED` beside the other PSYNC result constants. In `replicaProcessPsyncReply()` recognize the prefix before generic error handling:

```c
if (!strncmp(reply, "-FULLSYNCMEMORY", 15)) {
    serverLog(LL_NOTICE, "Primary rejected full synchronization for memory safety: %s", reply);
    sdsfree(reply);
    return PSYNC_FULLRESYNC_MEMORY_REJECTED;
}
```

Add the result to `getTryPsyncString()`. In `syncWithPrimary()`, handle it through `syncWithPrimaryHandleError(&conn)` and return. Do not enter the `PSYNC_NOT_SUPPORTED` path and do not send `SYNC`.

- [ ] **Step 5: Add and expose the rejection counter**

Add to `struct valkeyServer` with the other sync stats:

```c
long long stat_sync_full_rejected_memory;
```

Initialize it to zero beside `stat_sync_full` and expose it in `INFO stats` immediately after `sync_full`:

```c
"sync_full_rejected_memory:%lld\r\n", server.stat_sync_full_rejected_memory,
```

- [ ] **Step 6: Add boundary and isolation tests**

Extend the focused file with these exact behavioral assertions:

- Equality is admitted: set the advertised budget equal to a stable primary estimate using a direct PSYNC test client and assert the request is not rejected with `FULLSYNCMEMORY`.
- Budget one byte below the sampled estimate is rejected.
- Two replica clients advertising different budgets do not share state; the small-budget client is rejected and the large-budget client begins synchronization.
- `maxmemory 0` plus percentage `95` repeatedly leaves `sync_full` unchanged.

Use the test harness's raw client helper for direct PSYNC assertions so the normal server client's reconnect loop does not race the boundary checks.

- [ ] **Step 7: Run focused tests**

Run `./runtest --single tests/integration/replication-full-sync-memory.tcl`.

Expected: all tests pass with zero failures and leak checks pass.

- [ ] **Step 8: Leave Task 3 changes uncommitted**

Run `git status --short` and confirm only intended files are modified. Do not run `git commit`.

---

### Task 4: Verify partial-sync compatibility, unsupported primaries, and regressions

**Files:**
- Modify: `tests/integration/replication-full-sync-memory.tcl`
- Modify: `src/commands/psync.json` only if PSYNC metadata or accepted arguments changed during implementation
- Regenerate: `src/commands.def` only if command JSON changed

**Interfaces:**
- Verifies: the Task 2 handshake is critical only when the guard is active.
- Verifies: Task 3 admission occurs only after partial synchronization fails.
- Verifies: memory rejection never falls back to legacy `SYNC`.

- [ ] **Step 1: Add a partial-resynchronization test under a rejecting budget**

Perform one successful initial sync, disconnect the replica without discarding its cached primary, write a small amount of data on the primary, enable a budget smaller than current primary memory, and reconnect. Assert:

```tcl
assert_equal 1 [status $primary sync_partial_ok]
assert_equal $sync_full_before [status $primary sync_full]
assert_equal $rejected_before [status $primary sync_full_rejected_memory]
```

Use deltas rather than literal `1` if the surrounding server block performs earlier syncs.

- [ ] **Step 2: Add an unsupported-primary fail-closed test**

Use the replication test harness's fake-primary/raw-server pattern. It must:

1. Reply successfully to PING and existing handshake commands.
2. Reply `-ERR Unrecognized REPLCONF option` to `REPLCONF full-sync-memory-budget`.
3. Record subsequent commands.
4. Assert the guarded replica closes/retries without ever sending PSYNC on that connection.

Then repeat with percentage `0` and assert the replica does send PSYNC, proving default compatibility.

- [ ] **Step 3: Add a non-swapdb compatibility test**

Set the percentage to `95` with `repl-diskless-load disabled`, force a full sync, and assert it completes. This proves the configuration does not affect disk-based loading.

- [ ] **Step 4: Update command metadata only if required**

The recommended REPLCONF design does not change PSYNC arguments, so `src/commands/psync.json` and `src/commands.def` should remain unchanged. If implementation changes PSYNC syntax instead, stop and revise the spec before editing command metadata; silently adding optional PSYNC arguments would be ignored by older primaries and violate fail-closed compatibility.

- [ ] **Step 5: Format modified C and header files**

Run `clang-format-18 -i` on every modified `*.c` and `*.h` file when available. If it is unavailable, record that limitation and manually compare formatting with surrounding code.

- [ ] **Step 6: Run focused and regression verification**

Run, in order:

```bash
./runtest --single tests/integration/replication-full-sync-memory.tcl
./runtest --single tests/integration/replication.tcl
make noopt BUILD_TLS=yes MALLOC=jemalloc
make -C src commands.def
git diff --check
```

Expected:

- Focused tests: zero failures.
- Existing replication suite: zero failures.
- TLS/jemalloc no-opt build: exit zero.
- `commands.def`: up to date.
- `git diff --check`: exit zero.

- [ ] **Step 7: Review the final diff against the spec**

Confirm all of the following directly in the diff:

- Default behavior is unchanged.
- The guard is swapdb-only.
- `maxmemory 0` produces a zero budget.
- Partial sync executes before admission.
- Rejection occurs before every full-sync side effect listed in Task 3.
- Unsupported primary behavior fails closed before PSYNC.
- Logs include estimate and budget.
- `sync_full_rejected_memory` increments while `sync_full` does not.
- No abort/pause command or module API is required by this feature.

- [ ] **Step 8: Leave all implementation and documentation uncommitted**

Run:

```bash
git status --short --untracked-files=all
```

Report the modified and untracked files. Do not stage, commit, push, merge, or create a pull request unless the user explicitly requests that action later.
