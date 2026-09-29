import assert from 'node:assert/strict';
import test from 'node:test';
import Plugin from '../../../src/Cli/Plugin.mjs';

test('applies the host log policy at startup', async () => {
    const calls = [];
    const plugin = Plugin({
        cliConfig: {applicationRoot: '/tmp/pde-igor-host'},
        policy: {apply: async (params) => calls.push(params)},
    });

    await plugin.onStartup();
    await plugin.onShutdown();
    assert.deepEqual(calls, [{appRoot: '/tmp/pde-igor-host'}]);
});
