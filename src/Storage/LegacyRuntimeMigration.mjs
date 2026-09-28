// @ts-check

/**
 * @namespace Pde_Igor_Storage_LegacyRuntimeMigration
 * @description Rebuilds a recognized predecessor Runtime schema through TeqFW DEM.
 */

const SOURCE_NAMESPACE = 'legacy';

/** @returns {Promise<object>} */
async function loadDbFragment() {
    const {readFileSync} = await import('node:fs');
    const {join} = await import('node:path');
    const filename = join(import.meta.dirname, '../../node_modules/@teqfw/db/etc/teqfw.schema.json');
    return {declaration: Object.freeze(JSON.parse(readFileSync(filename, 'utf8'))), filename, fragmentId: 'teqfw.db.schema', packageName: 'teqfw.db.schema'};
}

const ENTITY = Object.freeze({
    client: '/pde/runtime/client', delegation: '/pde/runtime/delegation', audit: '/pde/runtime/audit/event',
    oauthClient: '/pde/runtime/oauth/client', oauthPolicy: '/pde/runtime/oauth/policy',
    accessToken: '/pde/runtime/oauth/token/access', refreshToken: '/pde/runtime/oauth/token/refresh',
    personSession: '/pde/runtime/person/session', mandate: '/pde/runtime/mandate',
    trustedPerson: '/pde/runtime/trusted/person', trustedPersonSession: '/pde/runtime/trusted/session',
    trustedPersonChallenge: '/pde/runtime/trusted/auth/challenge', trustedPersonLoginRequest: '/pde/runtime/trusted/auth/request',
    snapshot: '/teqfw/db/schema/snapshot', application: '/teqfw/db/schema/application',
});
const V3_ENTITIES = Object.freeze(['personSession', 'client', 'accessToken', 'refreshToken', 'oauthClient', 'oauthPolicy', 'delegation', 'audit']);
const PREVIOUS_ENTITIES = Object.freeze(['personSession', 'client', 'accessToken', 'refreshToken', 'oauthClient', 'oauthPolicy', 'delegation', 'audit', 'mandate', 'trustedPerson']);
const LEGACY_ENTITIES = Object.freeze(['accessToken', 'audit', 'delegation', 'oauthClient', 'personSession']);

/** @param {number} length @param {boolean} [nullable] @returns {object} */
const stringAttr = (length, nullable = false) => ({...(nullable ? {nullable: true} : {}), type: {id: 'core.string', params: {length}}});
/** @param {boolean} [nullable] @returns {object} */
const textAttr = (nullable = false) => ({...(nullable ? {nullable: true} : {}), type: {id: 'core.text', params: {}}});
/** @param {boolean} [nullable] @returns {object} */
const dateAttr = (nullable = false) => ({...(nullable ? {nullable: true} : {}), type: {id: 'core.datetime', params: {precision: 3, timezone: true}}});
/** @param {string} attr @returns {object} */
const primary = (attr) => ({kind: 'primary', keys: [{attr}], include: [], options: {}, phase: 'table'});
/** @param {string[]} attrs @returns {object} */
const btree = (attrs) => ({kind: 'index', method: 'core.btree', keys: attrs.map((attr) => ({attr})), include: [], options: {}, phase: 'afterRelations'});

const V3_ATTR = Object.freeze({
    client: Object.freeze({client_id: stringAttr(2048), connected_at: dateAttr(true), disconnected_at: dateAttr(true), last_activity_at: dateAttr(true)}),
    delegation: Object.freeze({authorization_revision: {type: {id: 'core.integer', params: {bits: 32}}}, capability_id: stringAttr(255), client_id: stringAttr(2048), created_at: dateAttr(), id: stringAttr(128), permission_json: textAttr(), revoked_at: dateAttr(true)}),
    audit: Object.freeze({capability_id: stringAttr(255, true), client_id: stringAttr(2048, true), decision: stringAttr(32, true), delegation_id: stringAttr(128, true), event_type: stringAttr(128), id: stringAttr(128), occurred_at: dateAttr(), operation_id: stringAttr(255, true), reason: stringAttr(255, true)}),
});

const LEGACY_ATTR = Object.freeze({
    accessToken: Object.freeze({client_id: stringAttr(2048), digest: stringAttr(128), expires_at: dateAttr(), issued_at: dateAttr(), resource: stringAttr(2048), scopes_json: textAttr()}),
    audit: Object.freeze({capability_id: stringAttr(255, true), client_id: stringAttr(2048, true), decision: stringAttr(32, true), delegation_id: stringAttr(128, true), event_type: stringAttr(128), id: stringAttr(128), occurred_at: dateAttr(), reason: stringAttr(255, true), resource: stringAttr(2048, true)}),
    delegation: Object.freeze({capability_id: stringAttr(255), client_id: stringAttr(2048), created_at: dateAttr(), id: stringAttr(128), resource: stringAttr(2048), resource_connection_id: stringAttr(1024, true), revoked_at: dateAttr(true)}),
});
const PREVIOUS_ATTR = Object.freeze({trustedPerson: Object.freeze({
    id: stringAttr(128), display_name: stringAttr(200), status: {type: {id: 'core.enum', params: {values: ['active', 'disabled', 'revoked']}}},
    created_at: dateAttr(), updated_at: dateAttr(),
})});

/** @param {object} declaration @param {string} path @returns {any} */
function entityAt(declaration, path) {
    const parts = path.split('/').filter(Boolean);
    let container = declaration;
    for (const part of parts.slice(0, -1)) container = container.package?.[part];
    const entity = container?.entity?.[parts.at(-1)];
    if (!entity) throw new Error(`Runtime DEM entity '${path}' is absent from the installed declaration.`);
    return entity;
}

/** @param {object} declaration @param {string} path @param {object} attr @param {object} index */
function replaceEntityShape(declaration, path, attr, index) {
    const entity = entityAt(declaration, path);
    entity.attr = attr;
    entity.index = index;
    entity.relation = {};
}

/** @param {object} declaration @param {'previous'|'v3'|'legacy'} variant @returns {object} */
function createSourceDeclaration(declaration, variant) {
    const source = structuredClone(declaration);
    if (variant === 'previous') {
        replaceEntityShape(source, ENTITY.trustedPerson, PREVIOUS_ATTR.trustedPerson, {pk: primary('id'), status: btree(['status'])});
    } else if (variant === 'v3') {
        replaceEntityShape(source, ENTITY.client, V3_ATTR.client, {pk: primary('client_id')});
        replaceEntityShape(source, ENTITY.delegation, V3_ATTR.delegation, {pk: primary('id'), lookup: btree(['client_id', 'capability_id'])});
        replaceEntityShape(source, ENTITY.audit, V3_ATTR.audit, {pk: primary('id'), time: btree(['occurred_at'])});
    } else {
        replaceEntityShape(source, ENTITY.accessToken, LEGACY_ATTR.accessToken, {pk: primary('digest'), expiry: btree(['expires_at'])});
        replaceEntityShape(source, ENTITY.audit, LEGACY_ATTR.audit, {pk: primary('id'), time: btree(['occurred_at'])});
        replaceEntityShape(source, ENTITY.delegation, LEGACY_ATTR.delegation, {pk: primary('id')});
    }
    return source;
}

/** @param {any} connection @param {string} name @returns {Promise<boolean>} */
async function hasTable(connection, name) {
    return connection.getSchemaBuilder().hasTable(name);
}

/** @param {any} connection @returns {Promise<boolean>} */
async function isEmptyDatabase(connection) {
    const adapter = await connection.getDialectAdapter().describe();
    if (adapter.id !== 'postgresql') return false;
    const result = await connection.getClient().raw(`
        SELECT NOT EXISTS (
            SELECT 1 FROM pg_class AS object
            JOIN pg_namespace AS schema ON schema.oid = object.relnamespace
            WHERE schema.nspname = 'public' AND object.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
        ) AS empty
    `);
    return result.rows?.[0]?.empty === true;
}

/** @param {readonly string[]} names @returns {readonly string[]} */
function cleanupOrder(names) {
    /** @param {string} name @returns {number} */
    const rank = (name) => name.endsWith('_teqfw_db_schema_application') ? 0
        : name.endsWith('_teqfw_db_schema_snapshot') ? 1 : 2;
    return [...new Set(names)].sort((left, right) => rank(left) - rank(right));
}

/**
 * @param {any} connection
 * @param {readonly string[]} names
 * @returns {Promise<readonly string[]>}
 */
async function dropSourceBackups(connection, names) {
    const removed = [];
    for (const name of cleanupOrder(names)) {
        if (!name.startsWith(`${SOURCE_NAMESPACE}_`)) throw new Error(`Refusing to remove a non-source table '${name}'.`);
        if (!await hasTable(connection, name)) continue;
        await connection.getSchemaBuilder().dropTableIfExists(name);
        removed.push(name);
    }
    return Object.freeze(removed);
}

/** @param {any} connection @param {string} name @returns {Promise<readonly string[]>} */
async function columnsOf(connection, name) {
    if (!await hasTable(connection, name)) return [];
    return Object.keys(await connection.getClient()(name).columnInfo()).sort();
}

/** @param {readonly string[]} actual @param {readonly string[]} expected @returns {boolean} */
function sameColumns(actual, expected) {
    const wanted = [...expected].sort();
    return actual.length === wanted.length && actual.every((name, index) => name === wanted[index]);
}

/** @param {any} targetCompilation @param {'previous'|'v3'|'legacy'} variant @returns {object} */
function predecessorDefinition(targetCompilation, variant) {
    const targetTables = Object.fromEntries(targetCompilation.physical.tables.map((table) => [table.entity, table.name]));
    const names = variant === 'previous'
        ? Object.fromEntries(PREVIOUS_ENTITIES.map((key) => [key, targetTables[ENTITY[key]]]))
        : variant === 'v3'
            ? Object.fromEntries(V3_ENTITIES.map((key) => [key, targetTables[ENTITY[key]]]))
        : {accessToken: 'pde_runtime_access_token', audit: 'pde_runtime_audit_event', delegation: 'pde_runtime_delegation', oauthClient: 'pde_runtime_oauth_client', personSession: 'pde_runtime_owner_session'};
    return Object.freeze({entities: variant === 'previous' ? PREVIOUS_ENTITIES : variant === 'v3' ? V3_ENTITIES : LEGACY_ENTITIES, names});
}

/** @param {any} connection @param {any} sourceCompilation @param {any} targetCompilation @param {'previous'|'v3'|'legacy'} variant @returns {Promise<object|null>} */
async function detectPredecessor(connection, sourceCompilation, targetCompilation, variant) {
    const definition = predecessorDefinition(targetCompilation, variant);
    const sourceNames = Object.fromEntries(sourceCompilation.physical.tables.map((table) => [table.entity, table.name]));
    const renames = [];
    for (const key of definition.entities) {
        const entity = ENTITY[key];
        const sourceTable = sourceCompilation.physical.tables.find((table) => table.entity === entity);
        const expected = sourceTable?.columns.map((column) => column.name) ?? [];
        const oldName = definition.names[key];
        const sourceName = sourceNames[entity];
        const sourceExists = await hasTable(connection, sourceName);
        const oldExists = await hasTable(connection, oldName);
        if (sourceExists && oldExists) return null;
        const actualName = sourceExists ? sourceName : oldExists ? oldName : null;
        if (!actualName || !sameColumns(await columnsOf(connection, actualName), expected)) return null;
        if (oldExists && !sourceExists) renames.push({from: oldName, to: sourceName});
    }
    return {definition, sourceNames, renames};
}

/** @param {any} row @param {any} active @returns {boolean} */
function isLater(row, active) {
    return !active || String(row.created_at).localeCompare(String(active.created_at)) > 0
        || (String(row.created_at) === String(active.created_at) && String(row.id).localeCompare(String(active.id), undefined, {numeric: true}) > 0);
}

/** @param {readonly any[]} rows @returns {Map<string, any>} */
function currentDelegations(rows) {
    const result = new Map();
    for (const row of rows) if (row.revoked_at == null) {
        const key = `${row.client_id}\u0000${row.capability_id}`;
        if (isLater(row, result.get(key))) result.set(key, row);
    }
    return result;
}

/** @param {any} compilation @returns {string} */
function historyApplicationTable(compilation) {
    const table = compilation.physical.tables.find((item) => item.entity === ENTITY.application);
    if (!table) throw new Error(`Compiled DEM does not contain the history application entity '${ENTITY.application}'.`);
    return table.name;
}

/** @param {object} deps @param {any} deps.compilation @param {any} deps.connection @param {number} deps.targetSnapshotId @returns {Promise<any>} */
async function findStartedApplication({compilation, connection, targetSnapshotId}) {
    return connection.getClient()(historyApplicationTable(compilation))
        .where({status: 'started', target_snapshot_id: targetSnapshotId}).orderBy('id', 'desc').first();
}

/** @param {any} connection @param {readonly string[]} sourceNames @returns {Promise<void>} */
async function isolateSourceNames(connection, sourceNames) {
    const description = await connection.getDialectAdapter().describe();
    if (sourceNames.length === 0) return;
    const db = connection.getClient();
    if (description.id.startsWith('sqlite')) {
        const indexes = await db('sqlite_master').select('name').where({type: 'index'}).whereIn('tbl_name', sourceNames);
        for (const {name} of indexes) if (!name.startsWith('sqlite_autoindex_')) await db.raw('DROP INDEX ??', [name]);
        return;
    }
    if (description.id !== 'postgresql') return;
    const {createHash} = await import('node:crypto');
    /** @param {string} kind @param {string} table @param {string} name @returns {string} */
    const backupName = (kind, table, name) => `legacy_${kind}_${createHash('md5').update(`${table}:${name}`).digest('hex')}`;
    const constraints = await db('pg_constraint as c')
        .join('pg_class as r', 'r.oid', 'c.conrelid')
        .join('pg_namespace as n', 'n.oid', 'r.relnamespace')
        .select('c.conname', 'r.relname')
        .where('n.nspname', 'public')
        .whereIn('r.relname', sourceNames);
    for (const {conname, relname} of constraints) {
        if (conname.startsWith('legacy_')) continue;
        await db.raw('ALTER TABLE ?? RENAME CONSTRAINT ?? TO ??', [relname, conname, backupName('c', relname, conname)]);
    }
    const indexes = await db('pg_indexes')
        .select('tablename', 'indexname')
        .where('schemaname', 'public')
        .whereIn('tablename', sourceNames);
    for (const {tablename, indexname} of indexes) {
        if (indexname.startsWith('legacy_')) continue;
        await db.raw('ALTER INDEX ?? RENAME TO ??', [indexname, backupName('i', tablename, indexname)]);
    }
}

/** @param {object} deps @param {any} deps.connection @param {any} deps.sourceCompilation @param {'previous'|'v3'|'legacy'} deps.variant @returns {Promise<object>} */
async function createSnapshotReader({connection, sourceCompilation, variant}) {
    const cache = new Map();
    const sourceByEntity = Object.fromEntries(sourceCompilation.physical.tables.map((table) => [table.entity, table]));
    /** @param {string} entity @returns {Promise<readonly any[]>} */
    const read = async (entity) => {
        if (cache.has(entity)) return cache.get(entity);
        const table = sourceByEntity[entity];
        const rows = table && await hasTable(connection, table.name) ? await connection.getClient()(table.name).select('*') : [];
        cache.set(entity, rows);
        return rows;
    };
    const delegationRows = await read(ENTITY.delegation);
    const active = currentDelegations(delegationRows);
    const snapshot = {
        readTable: async ({entity}) => {
            if (entity === ENTITY.client && !await hasTable(connection, sourceByEntity[entity].name)) {
                const ids = new Set();
                for (const key of [ENTITY.accessToken, ENTITY.refreshToken, ENTITY.oauthClient, ENTITY.delegation, ENTITY.audit]) {
                    for (const row of await read(key)) if (row.client_id) ids.add(row.client_id);
                }
                return [...ids].map((client_id) => ({client_id, controller_kind: 'person', controller_id: 'person', connected_at: null, disconnected_at: null, last_activity_at: null}));
            }
            return read(entity);
        },
    };
    const transformations = {
        [ENTITY.client]: {id: 'runtime-v3-client-controller-v1', exec: ({row}) => ({...row, controller_kind: 'person', controller_id: 'person'})},
        [ENTITY.delegation]: {
            id: variant === 'v3' ? 'runtime-v3-delegation-state-v1' : 'runtime-legacy-delegation-state-v1',
            exec: ({row}) => {
                const {resource, resource_connection_id, ...base} = row;
                const key = `${row.client_id}\u0000${row.capability_id}`;
                const current = row.revoked_at == null && active.get(key)?.id === row.id;
                return {
                    ...base,
                    permission_json: base.permission_json ?? JSON.stringify({legacy_resource: resource, legacy_resource_connection_id: resource_connection_id ?? null}),
                    authorization_revision: base.authorization_revision ?? 1,
                    status: row.revoked_at == null ? (current ? 'active' : 'superseded') : 'revoked', current_marker: current ? 'current' : null,
                    grantor_kind: 'person', grantor_id: 'person', mandate_id: null, mandate_generation: null,
                    superseded_at: current || row.revoked_at != null ? null : row.created_at, superseded_by: current || row.revoked_at != null ? null : active.get(key)?.id ?? null,
                };
            },
        },
        [ENTITY.audit]: {id: 'runtime-legacy-audit-operation-v1', exec: ({row}) => { const {resource, ...base} = row; return {...base, operation_id: base.operation_id ?? resource ?? null, trusted_person_id: null, mandate_id: null, mandate_generation: null, authority_kind: null, authority_id: null, grantor_kind: null, grantor_id: null}; }},
        [ENTITY.accessToken]: {id: 'runtime-legacy-access-endpoint-v1', exec: ({row}) => { const {resource, ...base} = row; return {...base, protected_endpoint: base.protected_endpoint ?? resource}; }},
    };
    if (variant === 'previous') transformations[ENTITY.trustedPerson] = {
        id: 'runtime-previous-trusted-person-email-v1',
        exec: ({row}) => ({...row, email_normalized: row.email_normalized ?? `legacy-${Buffer.from(String(row.id)).toString('base64url')}@invalid.local`}),
    };
    if (variant === 'v3') delete transformations[ENTITY.accessToken];
    if (variant === 'legacy') delete transformations[ENTITY.client];
    return {snapshot, transformations};
}

/** @param {object} deps @param {any} deps.history @param {any} deps.compilation @param {any} deps.connection @returns {Promise<object>} */
async function completeHistory({history, compilation, connection}) {
    const previous = await history.resolveLastApplied({compilation, connection});
    if (previous?.snapshot.fingerprint === compilation.effective.fingerprint) return Object.freeze({status: 'up-to-date'});
    const target = await history.recordSnapshot({compilation, connection});
    const existing = await findStartedApplication({compilation, connection, targetSnapshotId: target.id});
    let attempt = existing;
    if (!attempt) {
        try {
            attempt = await history.startApplication({compilation, connection, sourceSnapshotId: previous?.snapshot.id ?? null, targetSnapshotId: target.id});
        } catch (error) {
            attempt = await findStartedApplication({compilation, connection, targetSnapshotId: target.id});
            if (!attempt) throw error;
        }
    }
    try {
        await history.completeApplication({applicationId: attempt.id, compilation, connection});
    } catch (error) {
        try {
            await history.failApplication({applicationId: attempt.id, compilation, connection});
        } catch {
            // Preserve the original history error; the started attempt remains inspectable.
        }
        throw error;
    }
    return Object.freeze({status: 'migrated'});
}

export default class LegacyRuntimeMigration {
    /** @param {object} deps @param {TeqFw_Db_Back_Config} deps.config @param {TeqFw_Db_Back_RDb_Connect} deps.connection @param {TeqFw_Db_Back_RDb_Connect} deps.connectionFactory @param {TeqFw_Db_Back_Dem_Compile} deps.compile @param {TeqFw_Db_Back_RDb_Rebuild} deps.rebuild @param {TeqFw_Db_Back_RDb_History} deps.history @param {TeqFw_Db_Back_RDb_Schema} deps.schema @param {Pde_Runtime_Storage_Schema} deps.schemaProvider */
    constructor({config, connection, connectionFactory, compile, rebuild, history, schema, schemaProvider}) {
        /** @returns {Promise<object>} */
        this.execute = async function () {
            const startedConnection = !connection.getClient();
            let sourceConnection;
            if (startedConnection) await connection.init(config.get());
            try {
                const adapter = connection.getDialectAdapter();
                const dbFragment = await loadDbFragment();
                const runtime = schemaProvider.getFragmentEnvelope();
                const target = compile.assertResult({value: await compile.exec({adapter, fragments: [runtime, dbFragment], mapEnvelope: schemaProvider.getMapEnvelope()})});
                const targetCatalog = await history.validateCatalog({compilation: target, connection});
                if (targetCatalog.matches) {
                    const historyResult = await completeHistory({history, compilation: target, connection});
                    const sourceNames = target.physical.tables.map(({name}) => `${SOURCE_NAMESPACE}_${name}`);
                    const backups = await dropSourceBackups(connection, sourceNames);
                    return Object.freeze({...historyResult, backups});
                }
                if (await isEmptyDatabase(connection)) {
                    schema.setCompilation({compilation: target});
                    await schema.createAllTables({conn: connection});
                    const historyResult = await completeHistory({history, compilation: target, connection});
                    return Object.freeze({...historyResult, backups: []});
                }

                const sourceMap = {version: 2, namespace: SOURCE_NAMESPACE, ref: {}, deprecated: {}};
                let selected;
                /** @type {Array<'previous'|'v3'|'legacy'>} */
                const variants = ['previous', 'v3', 'legacy'];
                for (const variant of variants) {
                    const declaration = createSourceDeclaration(schemaProvider.getDeclaration(), variant);
                    const fragment = {declaration, filename: `pde.runtime://${variant}/teqfw.schema.json`, fragmentId: `pde.runtime.${variant}`, packageName: `pde.runtime.${variant}`};
                    const sourceCompilation = compile.assertResult({value: await compile.exec({adapter, fragments: [fragment, dbFragment], mapEnvelope: {declaration: sourceMap, filename: `pde.runtime://${variant}/map`, mapId: `pde.runtime.${variant}:map`, packageName: `pde.runtime.${variant}`}})});
                    const profile = await detectPredecessor(connection, sourceCompilation, target, variant);
                    if (profile) {
                        selected = {candidate: sourceCompilation, profile, variant};
                        break;
                    }
                }
                if (!selected) throw new Error('Database schema is neither the current Runtime DEM nor a recognized Runtime predecessor; no changes were made.');

                const targetNames = new Set(target.physical.tables.map((table) => table.name));
                const sourceOldNames = new Set(Object.values(selected.profile.definition.names));
                for (const name of targetNames) if (await hasTable(connection, name) && !sourceOldNames.has(name)) {
                    throw new Error(`Target DEM table '${name}' is already present while the predecessor is incomplete; inspect the database before retrying.`);
                }
                for (const rename of selected.profile.renames) {
                    if (await hasTable(connection, rename.to)) throw new Error(`Source backup table '${rename.to}' already exists; no changes were made.`);
                    await connection.getSchemaBuilder().renameTable(rename.from, rename.to);
                }
                const sourceTableNames = [];
                for (const name of Object.values(selected.profile.sourceNames)) if (await hasTable(connection, name)) sourceTableNames.push(name);
                await isolateSourceNames(connection, sourceTableNames);

                sourceConnection = connectionFactory;
                await sourceConnection.init(config.get());
                const {snapshot, transformations} = await createSnapshotReader({connection: sourceConnection, sourceCompilation: selected.candidate, variant: selected.variant});
                const evidence = await /** @type {any} */ (rebuild).exec({mode: 'parallel', compilation: target, sourceCompilation: selected.candidate, source: sourceConnection, target: connection, sourceId: `pde-igor:${selected.variant}:source`, targetId: 'pde-igor:runtime:target', snapshot, transformations});
                if (evidence.status !== 'complete' || !evidence.dataComplete || evidence.transaction.outcome !== 'committed'
                    || evidence.failures.length || evidence.tables.some((table) => table.status !== 'verified' || table.sourceRows !== table.targetRows)) {
                    throw new Error('Runtime DEM rebuild did not produce complete verified evidence; source tables were retained.');
                }
                const historyResult = await completeHistory({history, compilation: target, connection});
                const backups = await dropSourceBackups(connection, selected.profile.renames.map(({to}) => to));
                return Object.freeze({...historyResult, backups});
            } finally {
                if (sourceConnection) await sourceConnection.disconnect();
                if (startedConnection) await connection.disconnect();
            }
        };
        Object.freeze(this);
    }
}

export const __deps__ = Object.freeze({default: Object.freeze({
    config: 'TeqFw_Db_Back_Config$', connection: 'TeqFw_Db_Back_RDb_Connect$', connectionFactory: 'TeqFw_Db_Back_RDb_Connect$$', compile: 'TeqFw_Db_Back_Dem_Compile$',
    rebuild: 'TeqFw_Db_Back_RDb_Rebuild$', history: 'TeqFw_Db_Back_RDb_History$', schema: 'TeqFw_Db_Back_RDb_Schema$', schemaProvider: 'Pde_Runtime_Storage_Schema$',
})});
