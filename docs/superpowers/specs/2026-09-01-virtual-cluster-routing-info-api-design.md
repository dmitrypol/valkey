# Virtual Cluster Routing-Information API Design

## Purpose

Keep the virtual-cluster module's existing command-filter design, while letting it ask Valkey core for the authoritative key positions, key flags, hash slot, and cross-slot result for an arbitrary original command invocation.

This is deliberately smaller than the retained pre-execution-router proposal. It does not add a new command callback, alter command dispatch, emulate cluster mode, or make a module responsible for ACL enforcement.

## Background

The module's command filter can rewrite a supported data command such as `GET key` into an internal module command such as `VCLUSTER.ROUTE GET key`. The module then needs to reason about the original command's keys before returning a local response, a `MOVED` reply, or `CROSSSLOT`.

Hand-maintaining a catalog of key positions is brittle: Valkey already knows command key specifications, including variable and movable key layouts. A module should be able to reuse that authoritative knowledge without reimplementing it.

## Goals

- Return canonical key indexes and per-key flags for a supplied command argv.
- Return the normal Valkey hash slot when every routed key resolves to one slot.
- Report cross-slot input without creating a redirect or executing the command.
- Preserve the filter-based virtual-cluster architecture and its fallback path.
- Keep the API versioned and safe to feature-detect from modules.

## Non-goals

- No pre-execution routing callback or module-owned command execution.
- No changes to command filters, command lookup, ACL checks, replication, transactions, or cluster-bus behavior.
- No built-in static or read-only cluster mode.
- No attempt to make a standalone server answer all cluster-management commands in core.

## Public module API

Add a versioned output structure and two module APIs in `src/valkeymodule.h`:

```c
typedef struct {
    uint64_t version;
    int *key_indexes;
    uint64_t *key_flags;
    int num_keys;
    int slot;
    int cross_slot;
} ValkeyModuleCommandRoutingInfoV1;

#define ValkeyModuleCommandRoutingInfo ValkeyModuleCommandRoutingInfoV1

VALKEYMODULE_API int (*ValkeyModule_GetCommandRoutingInfo)(
    ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc,
    ValkeyModuleCommandRoutingInfo *info);
VALKEYMODULE_API void (*ValkeyModule_FreeCommandRoutingInfo)(
    ValkeyModuleCommandRoutingInfo *info);
```

`ValkeyModule_GetCommandRoutingInfo` returns `VALKEYMODULE_OK` only after it has initialized `info`. `key_indexes` use the same zero-based argv indexing convention as `ValkeyModule_GetCommandKeysWithFlags`. `slot` is a normal `0..16383` slot when `cross_slot` is false and at least one key is present; it is `-1` for no-key commands or cross-slot input. `key_flags` preserve the existing module key-flag representation. The caller owns the result until it calls `ValkeyModule_FreeCommandRoutingInfo`.

The API is optional for modules: an older Valkey server leaves its function pointer unavailable, so a module can retain a conservative static key-table fallback.

## Core implementation

Implement the helper in `src/module.c` using Valkey's existing command lookup and key-spec machinery. It must not invoke command execution or command filters.

1. Resolve the command name from `argv[0]` with ordinary module command lookup rules.
2. Obtain the command's keys and flags through the existing key-spec extraction path, including movable-key commands.
3. Convert returned keys to zero-based argv indexes and copy their flags into module-owned result storage.
4. Hash each extracted key using the normal cluster key-hash helper. If more than one non-identical slot occurs, set `cross_slot` and leave `slot` as `-1`.
5. Provide one free routine that releases all allocations and clears the structure.

The helper is informational. The caller decides how to use the result; it cannot bypass or change the server's normal command behavior.

## Module use

When the routing-information API exists, the virtual-cluster filter path will:

1. Preserve the original argv before its internal rewrite.
2. Ask core for the original command's routing information.
3. Reject a cross-slot request locally with the standard `CROSSSLOT` error.
4. Map the returned slot through its virtual topology and return local, `MOVED`, or policy-specific handling.
5. Use the existing static command metadata only when the API is unavailable.

This gives the module native coverage for variable key layouts without expanding core routing authority.

## Compatibility and rollout

The API is additive. Existing modules and servers retain existing behavior. A module compiled against a newer header must check that the loaded optional API pointer is non-NULL before use. The module fallback remains necessary for Valkey releases and Redis 7 servers that do not contain this API.

## Test strategy

- C module tests for fixed-position, variable-position, no-key, unknown-command, and movable-key command forms.
- Assertions for key indexes, key flags, a same-slot hash-tag pair, and a cross-slot pair.
- Existing command-filter tests must prove the module uses the core helper when present and retains its fallback when absent.
- Run Valkey module unit tests and the virtual-cluster Rust test suite without changing cluster-mode behavior.
