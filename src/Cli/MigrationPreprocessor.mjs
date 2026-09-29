// @ts-check

/**
 * @namespace Pde_Igor_Cli_MigrationPreprocessor
 * @description Routes the Runtime migration command to the host migration.
 */
export default () => {
    return function (dependency) {
        if (dependency.address !== 'Pde_Runtime_Cli_Command_DbMigrate') return dependency;
        return {...dependency, address: 'Pde_Igor_Cli_Command_LegacyRuntimeMigration'};
    };
}
