// 307 to an absolute URL on this deployment's own vercel.app host, so the
// proxy has to rewrite Location back to the custom domain.
export const dynamic = 'force-dynamic';

export function GET(request) {
  const host = request.headers.get('host');
  return new Response(null, {
    status: 307,
    headers: { Location: `https://${host}/?redirected=1`, 'Cache-Control': 'no-store' },
  });
}
