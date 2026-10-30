import { headers } from 'next/headers';

export const dynamic = 'force-dynamic';

export default async function Home() {
  const h = await headers();
  const rows = [
    ['branch', process.env.VERCEL_GIT_COMMIT_REF ?? '(local)'],
    ['commit', (process.env.VERCEL_GIT_COMMIT_SHA ?? '').slice(0, 7) || '(local)'],
    ['deployment url', process.env.VERCEL_URL ?? '(local)'],
    ['host', h.get('host')],
    ['x-forwarded-host', h.get('x-forwarded-host')],
    ['x-preview-host', h.get('x-preview-host')],
  ];

  return (
    <main>
      <h1>Preview proxy POC</h1>
      <table>
        <tbody>
          {rows.map(([k, v]) => (
            <tr key={k}>
              <th style={{ textAlign: 'left', paddingRight: 16 }}>{k}</th>
              <td><code data-field={k}>{v ?? '(none)'}</code></td>
            </tr>
          ))}
        </tbody>
      </table>
      <p>
        <a href="/redirect">/redirect</a> · <a href="/cookie">/cookie</a> · <a href="/api/echo">/api/echo</a>
      </p>
    </main>
  );
}
