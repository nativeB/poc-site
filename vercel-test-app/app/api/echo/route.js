// Echoes method, headers and body to check that requests pass through intact.
export const dynamic = 'force-dynamic';

const HIDDEN = new Set(['x-vercel-protection-bypass', 'authorization', 'cookie']);

async function echo(request) {
  const headers = Object.fromEntries(
    [...request.headers].map(([k, v]) => [k, HIDDEN.has(k) ? '(hidden)' : v]),
  );
  const body = ['GET', 'HEAD'].includes(request.method) ? null : await request.text();
  return Response.json(
    { method: request.method, url: request.url, headers, body },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}

export const GET = echo;
export const POST = echo;
export const PUT = echo;
export const PATCH = echo;
export const DELETE = echo;
