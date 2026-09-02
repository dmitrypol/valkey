# Virtual Cluster Routing-Information API Implementation Plan

> **For implementation:** execute in the existing checkouts only. Do not create a branch or worktree, stage files, commit, push, merge, or discard unrelated user changes.

**Goal:** Add a small optional Valkey module API that reports native command keys, key flags, slot, and cross-slot status, then use it to simplify the virtual-cluster module's existing filter path.

**Architecture:** Core exposes an informational helper built from existing command key specifications and cluster hashing. The virtual-cluster module remains the virtual-topology owner; it feature-detects the helper and falls back to its current static key metadata where the helper is unavailable.

**Spec:** `docs/superpowers/specs/2026-09-01-virtual-cluster-routing-info-api-design.md`

## Constraints

- Do not introduce a routing callback, change execution ordering, or modify ACL behavior.
- Do not enable cluster mode or add gossip, failover, migration, or cluster-bus behavior.
- Do not run filters or execute the supplied command while querying its routing information.
- Reuse native key specifications, including variable and movable key forms.
- Preserve the current fallback for older Valkey releases and Redis 7.

## Task 1: Define and expose the module API

**Files:**

- Modify: `src/valkeymodule.h`
- Modify: `src/module.c`
- Add or modify: focused module API tests under `tests/unit/moduleapi/`

**Steps:**

1. Add the versioned `ValkeyModuleCommandRoutingInfoV1` structure, alias, getter, and free function declarations.
2. Register the APIs as optional module symbols following nearby module API conventions.
3. Implement getter validation, result initialization, and one matching free function.
4. Write a focused test module/API test that verifies an ordinary fixed-key command reports its argv index and flags.
5. Build the server and run the focused test.

## Task 2: Derive slots from canonical command keys

**Files:**

- Modify: `src/module.c`
- Modify: the Task 1 module API tests

**Steps:**

1. Use the existing core key-extraction path after command lookup; do not duplicate command key specifications.
2. Copy returned key indexes and flags into the output structure.
3. Use the normal key-hash routine to calculate a common slot.
4. Mark mixed slots as `cross_slot=1` and `slot=-1`; mark no-key input as `slot=-1` and `cross_slot=0`.
5. Test same-slot hash tags, cross-slot keys, no-key commands, unknown commands, and a variable or movable-key command form.
6. Run `git diff --check`, the focused module API test, and relevant Valkey unit tests.

## Task 3: Consume the optional helper in virtual-cluster

**Files:**

- Modify: the Rust FFI/module API binding in `/Users/dpolyako/github/dmitrypol/valkey-virtual-cluster`
- Modify: its command-filter routing code and tests

**Steps:**

1. Add a minimal safe wrapper for the optional core API and its free routine.
2. Preserve the original command argv before the filter's internal rewrite.
3. Prefer core-provided keys and routing state when the API is available.
4. Keep the current static command metadata fallback when it is not available.
5. Return the standard `CROSSSLOT` error before virtual-topology routing for cross-slot input.
6. Add unit/integration coverage for helper-present and helper-absent behavior.

## Task 4: Document compatibility and verify the unchanged architecture

**Files:**

- Modify: module README or compatibility documentation only if existing documentation names the manual command catalog

**Steps:**

1. State that the core API is optional and does not make the module binary-compatible with older servers by itself.
2. State that Valkey 7/8/9 and Redis 7 continue through the fallback unless they carry this API.
3. Verify command-filter tests, core tests, Rust formatting/tests, and `git diff --check`.
4. Review the final diff to confirm it contains no router callback, no cluster-mode change, and no unrelated cleanup.
