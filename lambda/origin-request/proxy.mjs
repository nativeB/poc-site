// Origin-request logic: map <slug>.previews.<domain> to <slug>.vercel.app.
// Config is passed in (not read from env) because Lambda@Edge has no env vars.

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// A slug is allowed if it's a valid DNS label that starts with the project
// prefix and ends with the team suffix (e.g. "-quincys-projects"). The suffix
// stops other Vercel accounts' "poc-site-*" projects being served on our domain.
export function isAllowedSlug(label, prefix, suffix = '') {
  return (
    /^[a-z0-9-]{1,63}$/.test(label) &&
    label.length > prefix.length + suffix.length &&
    label.startsWith(prefix) &&
    label.endsWith(suffix)
  );
}

export function createHandler({ domain, prefix, suffix = '', bypassSecret = '' }) {
  const hostPattern = new RegExp(`^([^.]+)\\.previews\\.${escapeRegex(domain)}$`);

  return async (event) => {
    const request = event.Records[0].cf.request;
    const host = (request.headers.host?.[0]?.value ?? '').toLowerCase().replace(/:\d+$/, '');
    const slug = hostPattern.exec(host)?.[1];

    if (!slug || !isAllowedSlug(slug, prefix, suffix)) {
      return {
        status: '404',
        statusDescription: 'Not Found',
        headers: {
          'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }],
          'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
        },
        body: 'Preview not found\n',
      };
    }

    const target = `${slug}.vercel.app`;

    request.origin = {
      custom: {
        domainName: target,
        port: 443,
        protocol: 'https',
        sslProtocols: ['TLSv1.2'],
        readTimeout: 30,
        keepaliveTimeout: 5,
        path: '',
        customHeaders: {},
      },
    };

    request.headers.host = [{ key: 'Host', value: target }];
    request.headers['x-forwarded-host'] = [{ key: 'X-Forwarded-Host', value: host }];
    // Vercel may overwrite X-Forwarded-Host with its own host, so also send
    // the custom hostname in a header Vercel leaves alone.
    request.headers['x-preview-host'] = [{ key: 'X-Preview-Host', value: host }];

    if (bypassSecret) {
      request.headers['x-vercel-protection-bypass'] = [
        { key: 'x-vercel-protection-bypass', value: bypassSecret },
      ];
      request.headers['x-vercel-set-bypass-cookie'] = [
        { key: 'x-vercel-set-bypass-cookie', value: 'samesitenone' },
      ];
    }

    return request;
  };
}
