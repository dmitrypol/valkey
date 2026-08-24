# Swapdb Full-Sync Memory Admission Design

## Summary

Add an opt-in replica-side memory admission policy for full synchronization when `repl-diskless-load swapdb` is active. Before the replica asks for PSYNC, it computes the number of additional bytes that may be allocated without crossing a configured percentage of `maxmemory`. It sends that budget to a supporting primary during the replication handshake. If partial synchronization is impossible, the primary compares its current allocator usage with the replica's budget before starting or attaching the replica to an RDB background save.

The initial configuration is:

```text
repl-diskless-load-swapdb-max-memory-percent 0
```

`0` disables admission control and preserves current behavior. A value from `1` through `100` enables it. The intended production setting is `95`.

No full synchronization is started when the estimate exceeds the budget. The replica retains its current dataset and retries through the normal replication reconnect path. Partial synchronization is never rejected by this policy.

## Motivation

Swapdb diskless loading keeps the old dataset available while loading the replacement dataset into temporary databases. Its peak memory is approximately:

```text
X + Y + Z
```

- `X` is memory currently charged against the replica's `maxmemory` policy.
- `Y` is the memory represented by the primary at the point it accepts the full sync.
- `Z` is replication data and other allocations accumulated while the snapshot is produced, transferred, loaded, and caught up.

`Z` cannot be predicted exactly. The configured percentage reserves headroom for it and for allocator variance. The policy is an admission guard, not a proof that OOM is impossible.

The RDB wire length is not a safe value for `Y`. Compression and serialization make the byte stream substantially smaller or larger than the in-memory representation. Valkey already writes `zmalloc_used_memory()` into the RDB `used-mem` AUX field; using the same measurement on the primary before full-sync admission gives a conservative estimate without waiting for the RDB body.

## Goals

- Prevent a swapdb full synchronization from starting when the estimated peak would cross a configurable percentage of the replica's `maxmemory`.
- Decide before the primary starts or attaches the replica to an RDB background save.
- Preserve partial synchronization even when a full synchronization would be rejected.
- Preserve the replica's old dataset after rejection.
- Re-evaluate automatically on later reconnects so synchronization can proceed after memory pressure falls or `maxmemory` increases.
- Fail safely when the option is enabled against a primary that does not support the budget handshake.
- Add logs and a counter that make rejection visible to operators.

## Non-goals

- Predict the exact size of replication changes accumulated after snapshot creation (`Z`).
- Enforce a limit against host physical memory, RSS, or a cgroup limit.
- Apply the policy to `repl-diskless-load disabled`, `on-empty-db`, or `flush-before-load`.
- Abort or pause a full synchronization after it has begun.
- Replace normal `maxmemory` eviction behavior.
- Guarantee that a process cannot be OOM-killed after admission.
- Change legacy `SYNC` behavior.

## Alternatives Considered

### Recommended: replica budget sent before PSYNC

The replica sends `REPLCONF full-sync-memory-budget <bytes>` during the handshake. A supporting primary stores the budget on that connection. It tries partial synchronization normally. Only after PSYNC cannot continue does it compare its memory estimate with the budget.

Advantages:

- Rejects before `sync_full` is incremented, before a replica is queued for BGSAVE, and before COB begins accumulating for that replica.
- Keeps the policy and threshold on the at-risk replica.
- Allows partial synchronization regardless of the budget.
- Reuses the existing handshake and reconnect state machine.

Trade-off:

- An older primary rejects the new REPLCONF. With the option enabled, the replica must fail the handshake closed because it cannot safely determine whether a subsequent PSYNC would trigger a full sync.

### Extend `+FULLRESYNC` with the primary estimate

The primary could append `Y` to `+FULLRESYNC`, and the replica could disconnect after receiving it. This is protocol-compatible when capability-gated, but the primary may already have started BGSAVE and begun buffering changes. It prevents loading but does not meet the requirement that full sync not start.

### Abort while reading the RDB AUX header

The replica could inspect the existing `used-mem` AUX value and abort before loading most keys. This requires no handshake extension, but full sync and its primary-side work have already begun. It also depends on AUX ordering and still creates a reactive abort path. This is retained only as a possible future defense-in-depth check.

## Configuration Semantics

### `repl-diskless-load-swapdb-max-memory-percent`

- Type: integer.
- Range: `0` through `100` inclusive.
- Default: `0`.
- Runtime modifiable: yes.
- Effect: only when `repl-diskless-load` is `swapdb`.
- `0`: disabled; no budget is sent and behavior is unchanged.
- `1..100`: maximum allowed estimated memory as a percentage of `maxmemory`.

When enabled and `maxmemory` is zero, the calculated budget is zero. This intentionally prevents full synchronization because there is no configured denominator against which to enforce the requested percentage. Partial synchronization remains possible with a supporting primary.

Changing the percentage, `maxmemory`, or `repl-diskless-load` affects the next handshake attempt. It does not interrupt an established replication link.

## Memory Calculation

Immediately before sending the budget handshake, the replica calculates:

```text
limit = floor(maxmemory * percent / 100)
X = max(0, zmalloc_used_memory() - freeMemoryGetNotCountedMemory())
budget = max(0, limit - X)
```

The multiplication must avoid unsigned overflow by dividing `maxmemory` into quotient and remainder before multiplying by the percentage.

The primary calculates:

```text
Y = zmalloc_used_memory()
admit full sync when Y <= budget
```

Using total allocator usage for `Y` is deliberately conservative. It matches the existing RDB `used-mem` measurement and avoids underestimating functions, modules, allocator overhead, and dataset structures that may be represented in the incoming RDB. It may reject a sync that would have fit; operators can choose a higher percentage or temporarily disable the guard.

The primary evaluates `Y` immediately after partial synchronization fails and before any full-sync bookkeeping. The comparison uses `Y > budget`, so equality is admitted and matches the stated `X + Y <= limit` rule.

## Protocol and State Flow

1. The replica completes authentication and its existing REPLCONF handshake.
2. If the option is active for swapdb, it sends:

   ```text
   REPLCONF full-sync-memory-budget <unsigned-bytes>
   ```

3. A supporting primary validates the unsigned value, stores it in the connection's replication data, and replies `+OK`.
4. An unsupported primary replies with an error. Because the guard is enabled, the replica treats this as a critical handshake failure, closes the connection, retains its dataset, and retries later. It must not proceed to PSYNC or fall back to `SYNC`.
5. The replica sends its normal PSYNC request.
6. The primary attempts partial synchronization first. If it succeeds, the memory budget is ignored.
7. If partial synchronization fails and a budget was supplied, the primary samples `Y`.
8. If `Y > budget`, the primary increments `sync_full_rejected_memory`, sends a distinct `-FULLSYNCMEMORY` error containing estimate and budget, and returns before `stat_sync_full++`, replica-list insertion, backlog creation, BGSAVE attachment, or BGSAVE startup.
9. The replica recognizes `-FULLSYNCMEMORY` as transient, logs the rejection, returns to `REPL_STATE_CONNECT`, and lets replication cron retry. It must not fall back to legacy `SYNC`.
10. On each retry, the replica recomputes `X` and sends a new budget. The primary recomputes `Y`.

The budget lives only on the primary-side client connection and is cleared by normal client initialization/freeing. It is not global and cannot affect other replicas.

## Error Handling and Observability

Primary rejection response:

```text
-FULLSYNCMEMORY primary memory estimate <Y> exceeds replica full-sync budget <budget>
```

The exact message is diagnostic; protocol matching depends only on the `-FULLSYNCMEMORY` prefix.

The primary logs the replica name, `Y`, and budget at notice level. The replica logs `X`, `Y`, configured percentage, `maxmemory`, and budget when the values are available from the response and local state.

Add the cumulative primary statistic below to `INFO stats`:

```text
sync_full_rejected_memory:<count>
```

Rejected attempts do not increment `sync_full`, because no full synchronization started.

Malformed or overflowing budget arguments receive the normal REPLCONF error and do not set a budget. Unsupported-primary errors are critical only when this replica has enabled the guard; existing REPLCONF compatibility behavior remains unchanged otherwise.

## Compatibility

- Default configuration sends no new REPLCONF and has no protocol or behavior change.
- New replica, new primary, guard enabled: admission is enforced.
- New replica, old primary, guard enabled: fail closed before PSYNC; retry and retain the old dataset.
- New replica, any primary, guard disabled or non-swapdb load: existing behavior.
- Old replica, new primary: no budget is present; existing behavior.
- Partial synchronization with a supporting primary is attempted and may succeed even when `Y` exceeds the budget.
- Planned failover behavior remains unchanged; the normal replica handshake carries the budget, while special failover PSYNC semantics are not extended.

## Testing Strategy

Create `tests/integration/replication-full-sync-memory.tcl` with focused cases:

1. Configuration accepts `0`, `95`, and `100`, rejects values outside `0..100`, and round-trips through `CONFIG GET`.
2. With swapdb, a primary dataset estimate greater than the computed budget produces `-FULLSYNCMEMORY`, increments `sync_full_rejected_memory`, leaves `sync_full` unchanged, does not start BGSAVE for the replica, and preserves the replica's old dataset.
3. Raising replica `maxmemory` allows a later retry to pass admission and complete synchronization.
4. Reducing replica memory usage allows a later retry to pass admission.
5. A partial resynchronization succeeds even when the same budget would reject a full synchronization.
6. Percentage `0` preserves current full-sync behavior.
7. A non-swapdb diskless-load mode does not send or enforce the budget.
8. Enabled guard with `maxmemory 0` rejects full sync.
9. A fake or compatibility primary that rejects `REPLCONF full-sync-memory-budget` never receives PSYNC from the guarded replica.
10. Multiple replicas with different budgets are admitted or rejected independently.

Run the focused test, the existing replication integration suite, command metadata generation, a TLS/jemalloc no-opt build, and whitespace validation.

## Operational Guidance

The initial recommended value is `95`, but the correct headroom depends on workload churn, replication duration, allocator fragmentation, modules, and whether other processes share the memory limit. A lower percentage is safer and may delay recovery longer. A higher percentage improves availability but leaves less room for `Z`.

Operators should alert on `sync_full_rejected_memory` growth and the corresponding logs. Recovery options are to reduce replica memory usage, increase `maxmemory` and the actual container/host limit together, increase the percentage only if accepting greater OOM risk, or temporarily select a non-swapdb load policy with its documented availability/data-loss trade-offs.
