#!/usr/bin/env bash
# Acceptance checks from SPEC.md section 6.
#
# Usage:
#   scripts/smoke-test.sh <alpha-slug> <beta-slug>
#
# A slug is the part of a Vercel preview URL before ".vercel.app", e.g.
#   poc-site-git-feat-alpha-quincys-projects
#
# Optional env vars:
#   DOMAIN          default qhutch.click
#   ALPHA_BRANCH    default feat/alpha
#   BETA_BRANCH     default feat/beta
#   GAMMA_SLUG      slug of a brand-new branch, to run check 10
#   BYPASS_ON=1     set if Vercel Deployment Protection is on, to run check 11
set -uo pipefail

ALPHA=${1:?usage: smoke-test.sh <alpha-slug> <beta-slug>}
BETA=${2:?usage: smoke-test.sh <alpha-slug> <beta-slug>}
DOMAIN=${DOMAIN:-qhutch.click}
ALPHA_BRANCH=${ALPHA_BRANCH:-feat/alpha}
BETA_BRANCH=${BETA_BRANCH:-feat/beta}

A_HOST="$ALPHA.previews.$DOMAIN"
B_HOST="$BETA.previews.$DOMAIN"
pass=0; fail=0

result() { # result <num> <PASS|FAIL|WARN> <message>
  printf '%-3s %-5s %s\n' "$1" "$2" "$3"
  case $2 in PASS) pass=$((pass + 1)) ;; FAIL) fail=$((fail + 1)) ;; esac
}
field() { # field <html> <name>  -> value of data-field cell on the test app page
  printf '%s' "$1" | grep -o "data-field=\"$2\">[^<]*" | head -1 | sed 's/.*>//'
}

echo "Testing $A_HOST and $B_HOST"
echo

# 1. 200 with a valid TLS cert
for host in "$A_HOST" "$B_HOST"; do
  out=$(curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}' "https://$host/" 2>&1)
  if [ "$out" = "200 0" ]; then result 1 PASS "$host -> 200, TLS cert valid"
  else result 1 FAIL "$host -> $out"; fi
done

# 2. Per-branch routing
a_body=$(curl -sS "https://$A_HOST/")
b_body=$(curl -sS "https://$B_HOST/")
a_branch=$(field "$a_body" branch)
b_branch=$(field "$b_body" branch)
if [ "$a_branch" = "$ALPHA_BRANCH" ] && [ "$b_branch" = "$BETA_BRANCH" ]; then
  result 2 PASS "alpha shows '$a_branch', beta shows '$b_branch'"
else
  result 2 FAIL "alpha shows '$a_branch' (want $ALPHA_BRANCH), beta shows '$b_branch' (want $BETA_BRANCH)"
fi

# 3. App sees the custom hostname
xfh=$(field "$a_body" x-forwarded-host)
xph=$(field "$a_body" x-preview-host)
if [ "$xfh" = "$A_HOST" ]; then
  result 3 PASS "x-forwarded-host = $xfh"
elif [ "$xph" = "$A_HOST" ]; then
  result 3 WARN "Vercel overwrote x-forwarded-host ('$xfh'); x-preview-host = $xph"
else
  result 3 FAIL "x-forwarded-host = '$xfh', x-preview-host = '$xph'"
fi

# 4. Location rewrite
loc=$(curl -sS -o /dev/null -w '%{redirect_url}' "https://$A_HOST/redirect")
if [[ $loc == "https://$A_HOST/"* ]]; then result 4 PASS "Location: $loc"
else result 4 FAIL "Location: '$loc'"; fi

# 5. Set-Cookie without Domain=
cookies=$(curl -sS -D - -o /dev/null "https://$A_HOST/cookie" | grep -i '^set-cookie:' | tr -d '\r')
if [ -z "$cookies" ]; then result 5 FAIL "no Set-Cookie header"
elif printf '%s' "$cookies" | grep -qi 'domain='; then result 5 FAIL "Domain= still present: $cookies"
else result 5 PASS "$(printf '%s' "$cookies" | wc -l | tr -d ' ') Set-Cookie header(s), none with Domain="; fi

# 6. POST passthrough
echo_out=$(curl -sS -X POST -H 'Content-Type: application/json' -d '{"a":1}' "https://$A_HOST/api/echo")
if printf '%s' "$echo_out" | grep -q '"method":"POST"' && printf '%s' "$echo_out" | grep -q '"body":"{\\"a\\":1}"'; then
  result 6 PASS "POST method and body echoed"
else
  result 6 FAIL "unexpected echo: $(printf '%s' "$echo_out" | head -c 200)"
fi

# 7. Slug outside the prefix is refused
code=$(curl -sS -o /dev/null -w '%{http_code}' "https://evil-site.previews.$DOMAIN/")
if [ "$code" = "404" ]; then result 7 PASS "evil-site -> 404"
else result 7 FAIL "evil-site -> $code"; fi

# 8. HTTP redirects to HTTPS
out=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://$A_HOST/")
if [[ $out == 30[178]" https://$A_HOST/"* ]]; then result 8 PASS "http -> $out"
else result 8 FAIL "http -> $out"; fi

# 9. New commit shows up (manual)
result 9 INFO "alpha is on commit $(field "$a_body" commit). Push to $ALPHA_BRANCH, wait for Vercel, rerun: the commit should change."

# 10. Brand-new branch works with no infra change
if [ -n "${GAMMA_SLUG:-}" ]; then
  g_body=$(curl -sS "https://$GAMMA_SLUG.previews.$DOMAIN/")
  g_branch=$(field "$g_body" branch)
  if [ -n "$g_branch" ]; then result 10 PASS "gamma shows '$g_branch'"
  else result 10 FAIL "gamma page didn't load"; fi
else
  result 10 INFO "set GAMMA_SLUG=<slug of feat/gamma> to run this check"
fi

# 11. Deployment Protection bypass
if [ "${BYPASS_ON:-}" = "1" ]; then
  direct=$(curl -sS -o /dev/null -w '%{http_code}' "https://$ALPHA.vercel.app/")
  proxied=$(curl -sS -o /dev/null -w '%{http_code}' "https://$A_HOST/")
  if [ "$direct" = "401" ] && [ "$proxied" = "200" ]; then
    result 11 PASS "direct vercel.app -> 401, via proxy -> 200"
  else
    result 11 FAIL "direct vercel.app -> $direct, via proxy -> $proxied"
  fi
else
  result 11 INFO "skipped (set BYPASS_ON=1 if Deployment Protection is on)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
