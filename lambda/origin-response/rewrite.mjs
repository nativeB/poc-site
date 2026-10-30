// Origin-response logic: point Location headers back at the custom domain
// and drop Domain= from cookies so browsers accept them. Body is untouched.

// Same rule as origin-request/proxy.mjs (kept separate: each function ships
// as its own zip).
function isAllowedSlug(label, prefix, suffix = '') {
  return (
    /^[a-z0-9-]{1,63}$/.test(label) &&
    label.length > prefix.length + suffix.length &&
    label.startsWith(prefix) &&
    label.endsWith(suffix)
  );
}

const vercelLocation = /^https?:\/\/([a-z0-9-]+)\.vercel\.app(?::443)?(?=[/?#]|$)/i;

export function createHandler({ domain, prefix, suffix = '' }) {
  return async (event) => {
    const response = event.Records[0].cf.response;
    const headers = response.headers;

    // Only rewrite redirects to previews we proxy; leave vercel.com etc. alone.
    if (headers.location) {
      for (const h of headers.location) {
        h.value = h.value.replace(vercelLocation, (whole, label) => {
          const slug = label.toLowerCase();
          return isAllowedSlug(slug, prefix, suffix)
            ? `https://${slug}.previews.${domain}`
            : whole;
        });
      }
    }

    if (headers['set-cookie']) {
      for (const h of headers['set-cookie']) {
        h.value = h.value.replace(/;\s*domain=[^;]*/gi, '');
      }
    }

    return response;
  };
}
