// @ts-check

/**
 * @namespace Pde_Igor_Cli_Plugin
 * @description Applies the host default logging policy after configuration has loaded.
 */

/**
 * @param {object} deps
 * @param {TeqFw_Cli_Config} deps.cliConfig
 * @param {TeqFw_Cfg_Log_Policy} deps.policy
 * @returns {TeqFw_Cli_Api_Plugin}
 */
export default function Plugin({cliConfig, policy}) {
    return {
        async onStartup() {
            await policy.apply({appRoot: cliConfig.applicationRoot});
        },
        async onShutdown() {},
    };
}

export const __deps__ = Object.freeze({
    default: Object.freeze({
        cliConfig: 'TeqFw_Cli_Config$',
        policy: 'TeqFw_Cfg_Log_Policy$',
    }),
});
