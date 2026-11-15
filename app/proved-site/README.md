# proved-site

Public Cloudflare Worker for Proved. The page copy is `copy.md`. There is no login on the public pages and no payment API in this repo. A Pay button is a link to a Payment Link you create. If that link is not set, the button is disabled and says "Payment link not set yet".

| Route | Who |
| --- | --- |
| `GET /` | Offer, tiers, sample proof report, open source, FAQ, and Start onboarding |
| `GET /welcome` | Onboarding steps and the intake form |
| `POST /intake` | Validates the form, escapes it for HTML, drops the honeypot, rate-limits by IP, stores `intake:<timestamp>:<random>` in KV |
| `GET /admin/intakes` | Lists stored intakes. Needs `Authorization: Bearer <ADMIN_TOKEN>`. **404** when `ADMIN_TOKEN` is unset |

Header and footer always link to the plan at https://plan.rgnrk.co, plus `REPO_URL` and `CONTACT_EMAIL` when those are set.

## Run locally

Nothing here is deployed by these commands. npm cache goes to `/tmp` (see `.npmrc`).

```sh
cd ~/Developer/proved-site
npm install
mkdir -p /tmp/proved-site-vite /tmp/proved-site-vitest-cache
ln -sfn /tmp/proved-site-vite node_modules/.vite
ln -sfn /tmp/proved-site-vitest-cache node_modules/.vitest-cache
npm run check
```

`npm run check` is `tsc --noEmit` and `vitest run`. There is no vitest config file. The symlinks keep the test cache in `/tmp`. If a fresh `npm install` removes them, run the two `ln` lines again.

Optional local server (still no deploy):

```sh
npx wrangler dev
```

`wrangler dev` needs workerd's install script, which npm may have skipped. Allow it with `npm install-scripts approve workerd` and run `npm install` again. The KV id in `wrangler.toml` is still a placeholder, so this starts only after you replace it, or you pass a local binding. Public pages do not need a login.

## Go-live (the owner)

Do these yourself. This repo does not create the namespace, the Payment Links, or the route.

1. **KV namespace.** From this folder, with the repo's wrangler:

   ```sh
   npx wrangler kv namespace create SITE_KV
   ```

   Put the printed id in `wrangler.toml` in place of `REPLACE_WITH_YOUR_KV_NAMESPACE_ID`. Leave that placeholder until you have the real id.

2. **Stripe Payment Links.** In the Stripe Dashboard, make one Payment Link per tier (Intro and Standard). Do not use a Stripe API from this repo. Set each link's success URL to `https://<your-domain>/welcome` (the path is `/welcome`). Copy the `https://` link for each tier. This site never checks with Stripe that a payment went through. `/welcome` is the onboarding form either way.

3. **Env vars.** Set them as Worker secrets (they are not in `wrangler.toml`):

   ```sh
   openssl rand -base64 32
   npx wrangler secret put ADMIN_TOKEN
   npx wrangler secret put PAY_URL_INTRO
   npx wrangler secret put PAY_URL_STANDARD
   npx wrangler secret put REPO_URL
   npx wrangler secret put CONTACT_EMAIL
   ```

   Paste one value per prompt. `PAY_URL_INTRO` and `PAY_URL_STANDARD` are the Payment Link URLs from step 2. `REPO_URL` is the public `https://` repo URL. `CONTACT_EMAIL` is the address you want in the header and footer. `ADMIN_TOKEN` is the bearer secret for `GET /admin/intakes`.

   A new pricing tier uses the same rule: the env name is `PAY_URL_` plus the first word of the tier, uppercased. A bullet that starts `Rush job — [PRICE: owner sets] — ...` reads `PAY_URL_RUSH`.

4. **Deploy.**

   ```sh
   npx wrangler deploy
   ```

   `workers_dev` is false, so this does not publish a `*.workers.dev` URL.

5. **Route.** Attach the hostname you chose. Either add it in the dashboard (Workers → proved-site → Settings → Domains & Routes) or put a route in `wrangler.toml` before deploy, for example:

   ```toml
   routes = [
     { pattern = "YOUR_DOMAIN", custom_domain = true }
   ]
   ```

   Replace `YOUR_DOMAIN` with the real hostname. Use that same hostname in the Payment Link success URL from step 2 (`https://YOUR_DOMAIN/welcome`).

After it is up: open `/`, confirm a set Pay button goes to the Payment Link, pay a test if you want, and land on `/welcome`. List intakes with:

```sh
curl -sS -H "Authorization: Bearer <ADMIN_TOKEN>" https://YOUR_DOMAIN/admin/intakes
```

## Placeholders

| Placeholder | Where | What you do |
| --- | --- | --- |
| `[PRICE: owner sets]` | Intro and Standard in `copy.md` | Edit `copy.md` with the price, then deploy again |
| `[OTHER TIERS: owner decides whether to add any]` | Pricing | Add a tier bullet in `copy.md`, or delete the line |
| `[REPO_URL]` | Open source section, and the header/footer until `REPO_URL` is set | `wrangler secret put REPO_URL` |
| `[CONTACT_EMAIL]` | Header and footer until `CONTACT_EMAIL` is set | `wrangler secret put CONTACT_EMAIL` |
| `[owner decides]` | FAQ, who owns the work. The agreement template does not say | Edit `copy.md` |
| `[owner decides: cancellation and refunds]` | FAQ. The agreement only says a remote session can be ended at any time | Edit `copy.md` |
| `REPLACE_WITH_YOUR_KV_NAMESPACE_ID` | `wrangler.toml` | Paste the KV namespace id |
| Pay button "Payment link not set yet" | A tier whose `PAY_URL_<TIER>` is missing or not `https://` | `wrangler secret put PAY_URL_INTRO` and `PAY_URL_STANDARD` |
| `/admin/intakes` returns 404 | `ADMIN_TOKEN` unset or blank | `wrangler secret put ADMIN_TOKEN` |

The sample proof report also highlights the report template's own blanks (`[name]`, `[date]`, and the sentences in brackets). Those are filled in per job. They are not site settings.

## Intake

The form asks for the name and email (so the agreement can be sent) and the questions in `client-kit/checklists/intake.md`: what happened, when it last worked, the machine, what fixed looks like, what not to touch, whether there is a backup, and in person or remote.

- Honeypot field: `company_website`. If it is filled, the response looks like a thank-you and nothing is stored.
- Rate limit: 5 posts per IP per hour, from the first post in that hour. The IP is `CF-Connecting-IP`. A missing or odd value shares the bucket `unknown`. Validation failures count toward the limit.
- Stored key: `intake:<unix-ms>:<16 hex chars>`. The value is JSON. HTML is escaped when the page renders it.
- Rate-limit key: `rl:<ip>`.

`POST /intake` only accepts a normal form post (`application/x-www-form-urlencoded` or multipart). If the browser sends an Origin header, it has to match this site.
