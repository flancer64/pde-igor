import assert from 'node:assert/strict';
import test from 'node:test';
import LegacyRuntimeMigration from '../../../../src/Cli/Command/LegacyRuntimeMigration.mjs';

test('runs the host migration and reports its result', async () => {
    const output = [];
    const command = LegacyRuntimeMigration({
        migration: {execute: async () => ({status: 'migrated', backups: ['legacy_table']})},
        io: {write: (message) => output.push(message)},
    });

    assert.equal(command.id, 'db:migrate');
    await command.execute();
    assert.deepEqual(output, ['Runtime DEM migration migrated. Source backups removed: 1.\n']);
});
