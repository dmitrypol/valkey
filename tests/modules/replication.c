#include "valkeymodule.h"

int test_abort_replication_handshake(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    ValkeyModule_ReplyWithArray(ctx, 2);
    ValkeyModule_ReplyWithLongLong(ctx, ValkeyModule_AbortReplicationHandshake());
    ValkeyModule_ReplyWithLongLong(ctx, ValkeyModule_AbortReplicationHandshake());
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    if (ValkeyModule_Init(ctx, "replication", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (!ValkeyModule_AbortReplicationHandshake)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "test.abort_replication_handshake", test_abort_replication_handshake,
                                   "allow-stale", 0, 0, 0) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
