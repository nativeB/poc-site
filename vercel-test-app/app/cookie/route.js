// Sets a cookie scoped to this deployment's vercel.app host. Through the
// proxy, the Domain= attribute should be stripped.
export const dynamic = 'force-dynamic';

export function GET(request) {
  const host = request.headers.get('host');
  const headers = new Headers({ 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
  headers.append('Set-Cookie', `poc_domain=1; Domain=${host}; Path=/; Secure; HttpOnly; SameSite=Lax`);
  headers.append('Set-Cookie', 'poc_plain=1; Path=/; Secure; HttpOnly; SameSite=Lax');
  return new Response(`cookies set (origin host: ${host})\n`, { headers });
}
