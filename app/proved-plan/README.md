# proved-plan — passkey-locked launch checklist

A Cloudflare Worker that serves the Proved launch plan (`plan-content.md`) as an
interactive checklist at **https://plan.rgnrk.co**, locked to one passkey
(Touch ID / Face ID, platform authenticator, user verification required).

- 28 day tasks grouped by week, 4 daily-rhythm items that reset each day, and a daily
  numbers log (posts, replies, stars, outreach, calls, paid). Everything persists in KV.
- Single owner: the first and only passkey registers with the one-time `SETUP_TOKEN`
  secret. Once a credential exists, registration is closed, even with the token.
- Sessions: random 256-bit id in KV with a 7-day TTL; cookie
  `__Host-plan_sid` is `HttpOnly; Secure; SameSite=Strict; Max-Age=604800`.
- Every route except the login page (`GET /`) and the WebAuthn endpoints
  (`/auth/register/*`, `/auth/login/*`) needs a session; the rest answer 401.
- Edit `plan-content.md` and redeploy to change the plan (it is bundled as text).

## Check it locally (nothing is written outside /tmp)

```sh
cd ~/Developer/proved-plan
npm install          # npm cache goes to /tmp (see .npmrc)
npm run check        # tsc --noEmit + vitest
python3 -m unittest discover daemon/tests
```

There is no vitest config file (Vite would write a temp copy of it into `node_modules`), and
`node_modules/.vite` and `node_modules/.vitest-cache` are symlinks into `/tmp`, so a test run
writes nothing inside the project. If a fresh `npm install` removes them, recreate with
`ln -s /tmp/proved-plan-vite node_modules/.vite && ln -s /tmp/proved-plan-vitest-cache node_modules/.vitest-cache`
(the "fsModuleCache … could not be created" warning is expected and harmless).

The tests drive the real Worker with a software passkey (real ES256 signatures), so the
WebAuthn checks are exercised, not mocked.

## Deploy (the owner)

From `~/Developer/proved-plan`, with the repo's own wrangler:

```sh
npx wrangler login                          # 1. browser sign-in to the account that owns rgnrk.co
                                            #    (or: export CLOUDFLARE_API_TOKEN from 1Password for this shell)
npx wrangler kv namespace create PLAN_KV    # 2. put the printed id into wrangler.toml (REPLACE_WITH_YOUR_KV_NAMESPACE_ID)
openssl rand -base64 32                     # 3. a setup token; keep it only until step 6
npx wrangler secret put SETUP_TOKEN         #    paste it at the prompt (never into a file)
npx wrangler deploy                         # 4. also creates the plan.rgnrk.co custom domain + certificate
```

5. Check: Workers → proved-plan → Settings → Domains & Routes shows `plan.rgnrk.co` (`workers.dev` is off).
6. **Register your passkey**: on the Mac in Safari, open https://plan.rgnrk.co, paste the setup token under
   "First-time setup", tap **Register passkey**, confirm with Touch ID. You land on the checklist.
   Apple passkeys sync through iCloud Keychain, so your iPhone can then sign in with Face ID.
7. Close setup for good: `npx wrangler secret delete SETUP_TOKEN` (registration is already refused once a passkey exists).

Signing in later: open https://plan.rgnrk.co → **Sign in with passkey** → Touch ID / Face ID.

## Daily daemon

A LaunchAgent on this Mac does the page's morning work. It does not post.
Nothing is public until `daemon/approve.py` gets a YubiKey touch or a Mac
Secure Enclave Touch ID, and even then the default publisher only writes a
local preview.

What runs when: `daemon/com.ragnarok.plan-daemon.plist` starts
`/usr/bin/python3 ~/Developer/proved-plan/daemon/plan_daemon.py`
at minute 0 of every hour from 07:00 through 21:00 local time. Each run:

1. `GET /api/state?day=today` with the bearer token.
2. Reads the last 24 hours of `git log --all` in `~/Developer/ragnarok` and
   `~/Developer/proved-plan`, plus outcome fields from `~/.ragnarok/agents/*/state.json`.
3. Asks the Alexus model on the LAN (`llama3.1:8b` at `OLLAMA_URL` or `http://<ALEXUS_HOST>:11434/api/chat` from `~/.ragnarok/local.conf`,
   `num_ctx` 8192, `temperature` 0). The request sets `format` to a JSON schema
   (`post` string, `outreach` array of two strings) so the reply is that object.
   No other model is called. The two outreach strings are private drafts the owner
   might send by hand to two different people (a local business owner, or a
   developer who ships software). They are not addressed to a model or a server.
4. Writes `~/.ragnarok/plan-daemon/queue/<date>-post.md`, `<date>-outreach-1.md`,
   and `<date>-outreach-2.md`, appends every action to `~/.ragnarok/plan-daemon/log.jsonl`,
   and shows a macOS notification. Each file has a short header (`source:` and `day:`)
   and then the draft body. If all three are already `source: model` with a body,
   it logs and stays quiet, but step 1 still runs. If they are `source: fallback`
   because the model did not answer, the next run asks again and replaces them
   when a real draft comes back. A second failure leaves those files in place
   and does not notify again.
5. Does not tick the checklist. Outreach files are drafts and are never sent.

The plist points at this repo. Do not copy it into `~/Library/LaunchAgents`.
Load it yourself when you want it (this does not happen on deploy):

```sh
mkdir -p ~/.ragnarok/plan-daemon
umask 077
printf '%s\n' 'paste-the-same-value-you-gave-wrangler' > ~/.ragnarok/plan-daemon/token
launchctl bootstrap gui/$(id -u) ~/Developer/proved-plan/daemon/com.ragnarok.plan-daemon.plist
```

Stop it later with `launchctl bootout gui/501/com.ragnarok.plan-daemon`.

### Machine API secret

The daemon is not the passkey session. It uses a bearer token and sends
`User-Agent: proved-plan-daemon/1.0`. Cloudflare answers 403 error 1010 to
Python's default `Python-urllib` agent, so that request never reaches the Worker.
With `DAEMON_TOKEN` unset, `POST /api/check` and any bearer call to `GET /api/state`
or `POST /api/numbers` answer 404. Set it, then deploy, both by hand:

```sh
npx wrangler secret put DAEMON_TOKEN   # paste a long random value; it is not written to the repo
npx wrangler deploy
```

Put that same value in `~/.ragnarok/plan-daemon/token` (the plist reads
`DAEMON_TOKEN_FILE`, not a token baked into the repo). `POST /api/check` mirrors
the page checkboxes (`{id, done}` for a day task, `{day, id, done}` for a rhythm
item). `POST /api/numbers` is the same body the Save numbers button sends.

### Approve a post

The notification means a draft is waiting. Read it, then:

```sh
python3 ~/Developer/proved-plan/daemon/approve.py ~/.ragnarok/plan-daemon/queue/YYYY-MM-DD-post.md
```

The command prints the draft. If `fido2-token -L` lists a key, it runs
`fido-auth.sh` and continues only when that exits 0 and prints `AUTH_KEY_OK`.
Otherwise it runs `EnclaveAuthenticator` with a fresh 32-hex challenge and the
reason `post: ` plus the first 80 characters of the post body (not the queue
header), and continues only when the result is `ok: true` with that same
challenge and a signature. Cancel, timeout, a missing tool, or a mismatched
challenge stops it. The publisher is not called. The publisher receives the
post body only. A file whose `source:` is not `model` is refused before the
key prompt and before Touch ID, and the publisher is not called.

After a yes, the default `dryrun` backend writes what it would have posted to
`~/.ragnarok/plan-daemon/published/`. That is not a public post, so the checklist
is left alone. Any other `PLAN_PUBLISH_BACKEND` is a stub: it refuses, and it
will not log in, store a password, or post. The `post` rhythm box and the
`posts` number move only after a backend reports that a real post went out
(`published: true`). Running approve on an outreach file refuses and sends nothing.

### Lost the passkey?

Delete the KV key `cred:owner` in the dashboard (Workers → KV → PLAN_KV), set a new
`SETUP_TOKEN` (step 3) and register again (step 6).

### Local dev (optional)

`npx wrangler dev` needs workerd's install script, which npm skipped. Allow it with
`npm install-scripts approve workerd` and re-run `npm install`. WebAuthn needs the real
origin, so passkeys only work on https://plan.rgnrk.co (RP ID `plan.rgnrk.co`).

## Layout

| Path | What |
| --- | --- |
| `src/index.ts` | router, session gate, origin check on browser POSTs, machine-API bearer gate |
| `src/auth.ts` | WebAuthn registration/login (@simplewebauthn/server), single-owner rules |
| `src/session.ts` | KV sessions + cookie |
| `src/state.ts` | tasks, daily rhythm and numbers API (KV); `/api/check` shares those writes |
| `src/plan.ts` | parses `plan-content.md` |
| `src/pages.ts` | login page and checklist page (mobile-first, CSP nonce) |
| `test/` | P2–P7 tests with a software passkey and in-memory KV |
| `daemon/plan_daemon.py` | hourly drafter (local model, queue, notification) |
| `daemon/approve.py` | hardware gate; the only path that may call the publisher |
| `daemon/publish.py` | `dryrun` backend and the real-network stub |
| `daemon/com.ragnarok.plan-daemon.plist` | LaunchAgent, runs `plan_daemon.py` from this repo |

KV keys: `cred:owner`, `sess:<id>` (TTL 7 d), `chal:reg|auth:<id>` (TTL 5 min, single use),
`state:tasks`, `day:YYYY-MM-DD` (rhythm + numbers for that day).

Worker secret `DAEMON_TOKEN` (not a KV key) authorizes the machine API.
