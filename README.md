# Vercel preview proxy (POC)

Serves every Vercel preview deployment on our own wildcard domain, without Vercel's paid Preview Deployment Suffix add-on:

```
https://<vercel-slug>.previews.<domain>  ->  https://<vercel-slug>.vercel.app
```

New branches work automatically. There's no DNS, certificate or infrastructure change per preview.

This POC runs on a personal AWS account and a personal Vercel account with `domain = qhutch.click`. Production would use the same Terraform with `domain = ikhokha.red`.

## How it works

```
Browser
  │  https://poc-site-git-feat-alpha-quincys-projects.previews.qhutch.click
  ▼
Route 53     *.previews.<domain>  A/AAAA alias → CloudFront
  ▼
CloudFront   wildcard ACM cert, caching off, all viewer headers forwarded
  │
  ├─ origin-request Lambda@Edge
  │    - reads the slug from Host; it must start with the project prefix and end with the team slug (else 404)
  │    - points the origin at <slug>.vercel.app and sets Host to match
  │    - adds X-Forwarded-Host / X-Preview-Host (and the optional bypass header)
  ▼
Vercel       <slug>.vercel.app
  │
  └─ origin-response Lambda@Edge
       - rewrites Location: https://<slug>.vercel.app/... → https://<slug>.previews.<domain>/...
       - strips Domain= from Set-Cookie
```

## Repo layout

| Path | What it is |
|---|---|
| `infra/` | Terraform: ACM cert, Lambda@Edge, IAM role, CloudFront, Route 53 records, optional budget alert |
| `lambda/origin-request/` | Host → Vercel origin routing (`proxy.mjs`), entry point `index.mjs` |
| `lambda/origin-response/` | Location and cookie rewrites (`rewrite.mjs`), entry point `index.mjs` |
| `lambda/test/` | Unit tests (`node:test`) with mocked CloudFront events |
| `vercel-test-app/` | Minimal Next.js app with `/`, `/redirect`, `/cookie`, `/api/echo` |
| `scripts/smoke-test.sh` | End-to-end acceptance checks |

## Prerequisites

- A domain with a **public Route 53 hosted zone**
- AWS CLI profile with permission to manage ACM, Lambda, IAM, CloudFront and Route 53
- Terraform ≥ 1.5, Node.js ≥ 20
- A Vercel project connected to a GitHub repo

## 1. Deploy the Vercel test app

1. Push this repo to GitHub.
2. In Vercel, **Add New → Project**, import the repo, and set:
   - **Project name:** `poc-site` (this sets the slug prefix, `poc-site-`)
   - **Root Directory:** `vercel-test-app`
3. **Deployment Protection.** New Vercel projects protect previews with Vercel Authentication by default, so the proxy would get a login page. Pick one:
   - **Simplest:** Project → Settings → Deployment Protection → turn **Vercel Authentication** off.
   - **Keep protection:** enable **Protection Bypass for Automation**, copy the secret into `vercel_bypass_secret` in `terraform.tfvars`, and run the smoke test with `BYPASS_ON=1`.
4. Create two branches so there are two previews:
   ```bash
   git checkout -b feat/alpha && git commit --allow-empty -m "alpha" && git push -u origin feat/alpha
   git checkout -b feat/beta  && git commit --allow-empty -m "beta"  && git push -u origin feat/beta
   ```
5. Copy each preview's **branch URL** from the Vercel dashboard (Deployments → the deployment → Domains), e.g. `poc-site-git-feat-alpha-quincys-projects.vercel.app`. The slug is everything before `.vercel.app`. Use the slug Vercel shows; long branch names get truncated.

## 2. Test the Lambda functions locally

```bash
cd lambda
npm test
```

## 3. Deploy the AWS side

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan -out=tfplan                     # review before applying
terraform apply tfplan
```

The certificate validates in a few minutes. CloudFront then takes about 5–15 minutes to deploy. Check progress with:

```bash
aws cloudfront get-distribution --id "$(terraform output -raw distribution_id)" \
  --query Distribution.Status --profile <profile>        # wait for "Deployed"
```

## 4. Run the acceptance checks

```bash
scripts/smoke-test.sh <alpha-slug> <beta-slug>
# e.g.
scripts/smoke-test.sh poc-site-git-feat-alpha-quincys-projects poc-site-git-feat-beta-quincys-projects
```

The script prints PASS, FAIL, WARN or INFO for each check in SPEC.md section 6. Checks 9 and 10 need a manual step:

- **Check 9:** push a commit to `feat/alpha`, wait for Vercel to finish building, rerun the script, and confirm the `commit` value changed.
- **Check 10:** push a new branch `feat/gamma`, then rerun with `GAMMA_SLUG=<its slug>`.

## 5. Tear down

```bash
cd infra
terraform destroy
```

- **Lambda@Edge deletes slowly.** CloudFront keeps copies of the functions in edge locations. After the distribution is gone, those copies can take up to about an hour to clear, so the first `destroy` may fail on the two functions. Wait and run `terraform destroy` again.
- **Edge log groups.** Lambda@Edge writes logs to CloudWatch in whichever regions served traffic, named `/aws/lambda/us-east-1.vercel-preview-proxy-*`. Terraform doesn't manage these. Delete them with:
  ```bash
  for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text --profile <profile>); do
    for g in $(aws logs describe-log-groups --region "$r" --log-group-name-prefix /aws/lambda/us-east-1.vercel-preview-proxy \
                 --query 'logGroups[].logGroupName' --output text --profile <profile>); do
      aws logs delete-log-group --region "$r" --log-group-name "$g" --profile <profile> && echo "deleted $g ($r)"
    done
  done
  ```
- **Hosted zone.** The Route 53 hosted zone is not managed by Terraform, so it stays after destroy.

## Differences from SPEC.md

| Spec | This repo | Why |
|---|---|---|
| Origin request policy `AllViewerExceptHostHeader` | `AllViewer` | With Host excluded, the origin-request function only sees the placeholder origin host and can't tell which preview was requested. The function replaces Host with `<slug>.vercel.app` before the request reaches Vercel, so Vercel never sees the custom host in `Host`. |
| `include_body = true` | `false` | The function doesn't read the body, and CloudFront forwards it either way. Turning it on would only add Lambda's 1 MB body limit. |
| Node.js 20.x | `nodejs22.x` | Node 20 is end-of-life and being retired on Lambda. Override with `lambda_runtime` if needed. |
| Terraform renders `index.mjs` | Terraform renders `config.mjs` | Same idea: config is baked into the zip at deploy time. Keeping the logic in a plain file means it can be unit-tested without a build step. |
| Only `X-Forwarded-Host` | Also `X-Preview-Host` | Vercel may overwrite `X-Forwarded-Host` with its own host. `X-Preview-Host` is a fallback that reliably reaches the app. |

## Known limitations and risks

- **Absolute URLs built inside the app** from `VERCEL_URL` (Next.js `metadataBase`, OG images, auth callbacks, sitemaps) still point at `vercel.app`. Apps should prefer relative URLs or build absolute ones from the forwarded host header.
- **Auth providers** need `https://*.previews.<domain>` added to their OAuth or redirect allowlists.
- **Slug length.** Vercel truncates long branch slugs, so always use the slug Vercel generated rather than one derived from the branch name. Each DNS label is capped at 63 characters.
- **Deployment Protection.** Using the bypass secret makes previews public to anyone who can guess a URL through the proxy. In production, put WAF IP allowlisting, Cloudflare Access, or CloudFront signed cookies in front.
- **Lambda@Edge constraints.** There are no environment variables (config changes need a redeploy), everything must live in us-east-1, the body is capped at 1 MB if `include_body` is ever turned on, and deletes are slow.
- **Only the Location and Set-Cookie headers are rewritten.** Absolute `vercel.app` URLs inside HTML or JSON bodies are passed through unchanged.
- **Slug allowlist.** Without `vercel_slug_suffix`, anyone on Vercel could create a project named `poc-site-whatever` and have it served under our domain, which is a phishing risk. Always set the suffix to the team slug (for example `-ikhokha`). It's a strong filter but not airtight, because Vercel project names are first-come. For production, add an allowlist check against the Vercel API or put access control in front.

## Costs

At POC volume this is effectively free:

| Item | Cost |
|---|---|
| ACM certificate | Free |
| CloudFront | Free tier: 1 TB and 10M requests a month |
| Route 53 alias queries to CloudFront | Free |
| Lambda@Edge | About $0.60 per million requests per function, plus compute. Cents at POC volume |
| Route 53 hosted zone | $0.50 a month |
| AWS budget alert (optional) | Free (first two budgets) |

Set `budget_alert_email` to get an email if monthly spend passes `budget_limit_usd` (default $1).
