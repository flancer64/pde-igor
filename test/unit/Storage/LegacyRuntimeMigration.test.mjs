import assert from 'node:assert/strict';
import test from 'node:test';
import LegacyRuntimeMigration from '../../../src/Storage/LegacyRuntimeMigration.mjs';

test('leaves an already current schema untouched', async () => {
    let rebuildCalls = 0;
    const compilation = {
        effective: {fingerprint: 'current-fingerprint'},
        physical: {tables: [{entity: '/pde/runtime/client', name: 'pde_runtime_client'}]},
    };
    const connection = {
        getClient: () => ({}),
        getDialectAdapter: () => ({}),
        getSchemaBuilder: () => ({hasTable: async () => false}),
    };
    const migration = new LegacyRuntimeMigration({
        config: {get: () => ({})},
        connection,
        connectionFactory: {init: async () => { throw new Error('Unexpected source connection'); }},
        compile: {exec: async () => compilation, assertResult: ({value}) => value},
        rebuild: {exec: async () => { rebuildCalls++; }},
        history: {
            validateCatalog: async () => ({matches: true}),
            resolveLastApplied: async () => ({snapshot: {fingerprint: 'current-fingerprint'}}),
        },
        schema: {createAllTables: async () => { throw new Error('Unexpected schema write'); }},
        schemaProvider: {getFragmentEnvelope: () => ({}), getMapEnvelope: () => ({})},
    });

    assert.deepEqual(await migration.execute(), {status: 'up-to-date', backups: []});
    assert.equal(rebuildCalls, 0);
});
