// @ts-check

/**
 * @namespace Pde_Igor_Cli_Command_LegacyRuntimeMigration
 * @description Runs the explicit legacy Runtime DEM migration.
 */

/** @param {object} deps @param {any} deps.migration @param {TeqFw_Cli_Adapter_Io} deps.io @returns {any} */
export default function LegacyRuntimeMigration({migration, io}) {
    return Object.freeze({id: 'db:migrate', summary: 'Rebuild the Runtime DEM from a recognized predecessor and remove source backups after verification.', lifetime: 'finite', execute: async function () {
        const result = await migration.execute();
        io.write(`Runtime DEM migration ${result.status}. Source backups removed: ${result.backups.length}.\n`);
    }});
}

export const __deps__ = Object.freeze({default: Object.freeze({migration: 'Pde_Igor_Storage_LegacyRuntimeMigration$', io: 'TeqFw_Cli_Adapter_Io$'})});
