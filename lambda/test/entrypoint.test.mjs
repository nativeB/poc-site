// Packs each function the way Terraform does (index.mjs + logic file +
// generated config.mjs) and checks the entry point loads and works.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, cp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const lambdaDir = join(dirname(fileURLToPath(import.meta.url)), '..');

async function pack(fn, config) {
  const dir = await mkdtemp(join(tmpdir(), `${fn}-`));
  await cp(join(lambdaDir, fn), dir, { recursive: true });
  // Same format Terraform writes: "export default <json>;"
  await writeFile(join(dir, 'config.mjs'), `export default ${JSON.stringify(config)};\n`);
  return import(pathToFileURL(join(dir, 'index.mjs')).href);
}

test('origin-request entry point uses the generated config', async () => {
  const { handler } = await pack('origin-request', { domain: 'qhutch.click', prefix: 'poc-site-', suffix: '-team', bypassSecret: '' });
  const req = await handler({
    Records: [{ cf: { request: { headers: { host: [{ key: 'Host', value: 'poc-site-a-team.previews.qhutch.click' }] } } } }],
  });
  assert.equal(req.origin.custom.domainName, 'poc-site-a-team.vercel.app');
  const denied = await handler({
    Records: [{ cf: { request: { headers: { host: [{ key: 'Host', value: 'poc-site-a.previews.qhutch.click' }] } } } }],
  });
  assert.equal(denied.status, '404');
});

test('origin-response entry point uses the generated config', async () => {
  const { handler } = await pack('origin-response', { domain: 'qhutch.click', prefix: 'poc-site-', suffix: '' });
  const res = await handler({
    Records: [{ cf: { response: { headers: { location: [{ key: 'Location', value: 'https://poc-site-a.vercel.app/x' }] } } } }],
  });
  assert.equal(res.headers.location[0].value, 'https://poc-site-a.previews.qhutch.click/x');
});
