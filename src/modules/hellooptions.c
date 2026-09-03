/* Command options API example -- Register a command and its metadata in one call. */

#include "../valkeymodule.h"

/* HELLOOPTIONS.GET key
 * Return the string value stored at key. */
int HelloOptionsGet_ValkeyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);

    ValkeyModuleCallReply *reply = ValkeyModule_Call(ctx, "GET", "s", argv[1]);
    if (!reply) return ValkeyModule_ReplyWithError(ctx, "ERR GET failed");
    ValkeyModule_ReplyWithCallReply(ctx, reply);
    ValkeyModule_FreeCallReply(reply);
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);

    if (ValkeyModule_Init(ctx, "hellooptions", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    ValkeyModuleCommandOptions options = {
        .version = VALKEYMODULE_COMMAND_OPTIONS_VERSION,
        .flags = "readonly fast",
        .key_specs = (ValkeyModuleCommandKeySpec[]){
            {
                .flags = VALKEYMODULE_CMD_KEY_RO | VALKEYMODULE_CMD_KEY_ACCESS,
                .begin_search_type = VALKEYMODULE_KSPEC_BS_INDEX,
                .bs.index.pos = 1,
            },
            {0}
        },
        .acl_categories = "read fast",
        .summary = "Returns the string value stored at a key.",
    };
    return ValkeyModule_CreateCommandWithOptions(ctx, "hellooptions.get", HelloOptionsGet_ValkeyCommand, &options);
}
