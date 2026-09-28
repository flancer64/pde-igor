// @ts-check

/**
 * @namespace Pde_Igor_Bootstrap_DiConfig
 * @description Reserved as a host-specific configuration hook for future use.
 */
export default class Configurator {
    /**
     * @param {object} deps
     * @param {ReadonlyArray<string>} deps.argv
     * @returns {TeqFw_Cli_Api_Container_Configurator_Configuration}
     */
    configure({argv}) {
        const preprocessors = [];
        if (argv.includes('db:migrate')) preprocessors.push(function (dependency) {
            if (dependency.moduleName !== 'Pde_Runtime_Cli_Command_DbMigrate') return dependency;
            return Object.freeze({...dependency, moduleName: 'Pde_Igor_Cli_Command_LegacyRuntimeMigration'});
        });
        return {preprocessors};
    }
}
