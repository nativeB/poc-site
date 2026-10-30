import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../origin-request/proxy.mjs';

const config = { domain: 'qhutch.click', prefix: 'poc-site-' };

function event(host, extraHeaders = {}) {
  return {
    Records: [{
      cf: {
        config: { eventType: 'origin-request' },
        request: {
          method: 'GET',
          uri: '/',
          querystring: '',
          headers: { host: [{ key: 'Host', value: host }], ...extraHeaders },
          origin: { custom: { domainName: 'vercel.app', port: 443, protocol: 'https', path: '' } },
        },
      },
    }],
  };
}

const slug = 'poc-site-git-feat-alpha-quincys-projects';

test('routes a valid preview host to its vercel.app origin', async () => {
  const req = await createHandler(config)(event(`${slug}.previews.qhutch.click`));
  assert.deepEqual(req.origin.custom, {
    domainName: `${slug}.vercel.app`,
    port: 443,
    protocol: 'https',
    sslProtocols: ['TLSv1.2'],
    readTimeout: 30,
    keepaliveTimeout: 5,
    path: '',
    customHeaders: {},
  });
  assert.equal(req.headers.host[0].value, `${slug}.vercel.app`);
  assert.equal(req.headers['x-forwarded-host'][0].value, `${slug}.previews.qhutch.click`);
  assert.equal(req.headers['x-preview-host'][0].value, `${slug}.previews.qhutch.click`);
});

test('is case-insensitive and ignores a port in Host', async () => {
  const req = await createHandler(config)(event(`POC-SITE-ABC123.previews.QHUTCH.click:443`));
  assert.equal(req.origin.custom.domainName, 'poc-site-abc123.vercel.app');
});

test('keeps the request body and other headers', async () => {
  const e = event(`${slug}.previews.qhutch.click`, {
    'content-type': [{ key: 'Content-Type', value: 'application/json' }],
  });
  e.Records[0].cf.request.method = 'POST';
  e.Records[0].cf.request.body = { action: 'read-only', encoding: 'base64', data: 'eyJhIjoxfQ==' };
  const req = await createHandler(config)(e);
  assert.equal(req.method, 'POST');
  assert.equal(req.body.data, 'eyJhIjoxfQ==');
  assert.equal(req.headers['content-type'][0].value, 'application/json');
});

for (const host of [
  'evil-site.previews.qhutch.click', // outside the prefix
  'poc-site-.previews.qhutch.click', // empty slug
  `${slug}.previews.qhutch.click.evil.com`, // suffix attack
  `${slug}.qhutch.click`, // missing previews label
  `a.${slug}.previews.qhutch.click`, // extra label
  `poc-site-x_y.previews.qhutch.click`, // invalid char
  `poc-site-${'a'.repeat(64)}.previews.qhutch.click`, // too long
  'previews.qhutch.click',
  '',
]) {
  test(`returns 404 for host "${host}"`, async () => {
    const res = await createHandler(config)(event(host));
    assert.equal(res.status, '404');
    assert.equal(res.origin, undefined);
  });
}

test('returns 404 when Host header is missing', async () => {
  const e = event('x');
  delete e.Records[0].cf.request.headers.host;
  const res = await createHandler(config)(e);
  assert.equal(res.status, '404');
});

test('adds bypass headers only when a secret is configured', async () => {
  const host = `${slug}.previews.qhutch.click`;
  const without = await createHandler(config)(event(host));
  assert.equal(without.headers['x-vercel-protection-bypass'], undefined);

  const withSecret = await createHandler({ ...config, bypassSecret: 's3cret' })(event(host));
  assert.equal(withSecret.headers['x-vercel-protection-bypass'][0].value, 's3cret');
  assert.equal(withSecret.headers['x-vercel-set-bypass-cookie'][0].value, 'samesitenone');
});

test('treats dots in the domain literally', async () => {
  const handler = createHandler({ domain: 'qhutch.click', prefix: 'p-' });
  assert.equal((await handler(event('p-a.previewsXqhutchXclick'))).status, '404');
  assert.equal((await handler(event('p-a.previews.qhutchXclick'))).status, '404');
  assert.equal((await handler(event('p-a.previews.qhutch.click'))).origin.custom.domainName, 'p-a.vercel.app');
});

test('with a suffix, only slugs ending in the team slug are proxied', async () => {
  const handler = createHandler({ ...config, suffix: '-quincys-projects' });
  const ok = await handler(event(`${slug}.previews.qhutch.click`));
  assert.equal(ok.origin.custom.domainName, `${slug}.vercel.app`);

  for (const label of [
    'poc-site-phish', // someone else's project with our prefix
    'poc-site-git-main-other-team',
    'poc-site-quincys-projects', // prefix and suffix overlap, nothing in between
    'poc-site-x-quincys-projects-evil',
  ]) {
    const res = await handler(event(`${label}.previews.qhutch.click`));
    assert.equal(res.status, '404', label);
  }
});
