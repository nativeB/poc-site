import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../origin-response/rewrite.mjs';

const handler = createHandler({ domain: 'qhutch.click', prefix: 'poc-site-' });
const slug = 'poc-site-git-feat-alpha-quincys-projects';

function event(headers, body) {
  return {
    Records: [{
      cf: {
        config: { eventType: 'origin-response' },
        request: { headers: { host: [{ key: 'Host', value: `${slug}.vercel.app` }] } },
        response: { status: '200', statusDescription: 'OK', headers, ...(body && { body }) },
      },
    }],
  };
}

const location = (value) => ({ location: [{ key: 'Location', value }] });

test('rewrites an absolute vercel.app Location to the custom domain', async () => {
  const res = await handler(event(location(`https://${slug}.vercel.app/after?x=1#top`)));
  assert.equal(res.headers.location[0].value, `https://${slug}.previews.qhutch.click/after?x=1#top`);
});

test('rewrites http and explicit :443 to https on the custom domain', async () => {
  const a = await handler(event(location(`http://${slug}.vercel.app/a`)));
  assert.equal(a.headers.location[0].value, `https://${slug}.previews.qhutch.click/a`);
  const b = await handler(event(location(`https://${slug}.vercel.app:443/b`)));
  assert.equal(b.headers.location[0].value, `https://${slug}.previews.qhutch.click/b`);
  const c = await handler(event(location(`https://${slug}.vercel.app`)));
  assert.equal(c.headers.location[0].value, `https://${slug}.previews.qhutch.click`);
});

for (const value of [
  '/relative/path',
  'https://vercel.com/login?next=/',
  'https://other-project.vercel.app/',
  `https://${slug}.vercel.app.evil.com/`,
  'https://example.com/?u=https://poc-site-a.vercel.app/',
]) {
  test(`leaves Location "${value}" alone`, async () => {
    const res = await handler(event(location(value)));
    assert.equal(res.headers.location[0].value, value);
  });
}

test('with a suffix, leaves redirects to other teams\' previews alone', async () => {
  const strict = createHandler({ domain: 'qhutch.click', prefix: 'poc-site-', suffix: '-quincys-projects' });
  const ours = await strict(event(location(`https://${slug}.vercel.app/x`)));
  assert.equal(ours.headers.location[0].value, `https://${slug}.previews.qhutch.click/x`);
  const theirs = await strict(event(location('https://poc-site-phish.vercel.app/x')));
  assert.equal(theirs.headers.location[0].value, 'https://poc-site-phish.vercel.app/x');
});

test('strips Domain= from every Set-Cookie header, any case and position', async () => {
  const res = await handler(event({
    'set-cookie': [
      { key: 'Set-Cookie', value: `a=1; Domain=${slug}.vercel.app; Path=/; Secure` },
      { key: 'Set-Cookie', value: 'b=2; Path=/; domain=.vercel.app' },
      { key: 'Set-Cookie', value: 'c=3; Path=/; HttpOnly' },
    ],
  }));
  assert.deepEqual(
    res.headers['set-cookie'].map((h) => h.value),
    ['a=1; Path=/; Secure', 'b=2; Path=/', 'c=3; Path=/; HttpOnly'],
  );
});

test('does not touch the body or unrelated headers', async () => {
  const headers = { 'content-type': [{ key: 'Content-Type', value: 'text/html' }] };
  const res = await handler(event(headers, 'should stay'));
  assert.equal(res.body, 'should stay');
  assert.equal(res.headers['content-type'][0].value, 'text/html');
  assert.equal(res.status, '200');
});
