import assert from 'node:assert/strict';
import test from 'node:test';
import MigrationPreprocessor from '../../../src/Cli/MigrationPreprocessor.mjs';

test('routes only the Runtime migration command', () => {
    const preprocess = MigrationPreprocessor();
    const migration = Object.freeze({address: 'Pde_Runtime_Cli_Command_DbMigrate', lifestyle: 'singleton'});
    const other = Object.freeze({address: 'Pde_Runtime_Storage_Database', lifestyle: 'singleton'});

    assert.deepEqual(preprocess(migration), {
        address: 'Pde_Igor_Cli_Command_LegacyRuntimeMigration', lifestyle: 'singleton',
    });
    assert.equal(preprocess(other), other);
});
