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
        return {container: {
            preprocessors: argv.includes('db:migrate') ? ['Pde_Igor_Cli_MigrationPreprocessor$'] : [],
        }};
    }
}
