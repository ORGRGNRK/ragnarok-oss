import type { StoredIntake } from './admin';
import { SECTION_IDS, parsePricing, sectionByTitle, type Copy, type Section, type SectionTitle } from './copy';
import type { Env } from './env';
import { escapeHtml, validEmail, validHttps } from './http';
import { EMPTY_INTAKE, type Intake } from './intake';
import { applyRepoUrl, inline, renderMarkdown } from './render';

const STYLE = `
:root{color-scheme:dark;--bg:#0d0d0d;--void:#000;--card:#111;--card-2:#151515;--ink:#e8e8e8;--ink-2:#d4d4d4;--mute:#9ca3af;--faint:#666;--line:#1f1f1f;--line-2:#333;--gold:#c9a84c;--gold-bright:#ffe680;--gold-dim:rgba(201,168,76,.55);--gold-haze:rgba(201,168,76,.12);--warn:#ef4444;--up:#22c55e;--wait:#f59e0b;--display:'Courier New',Courier,monospace;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,"Helvetica Neue",Arial,sans-serif;--mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#0d0d0d}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg) radial-gradient(ellipse 70% 40% at 50% 0,var(--gold-haze),transparent 70%) no-repeat;color:var(--ink);font:16px/1.6 var(--sans);-webkit-text-size-adjust:100%;min-height:100vh}
a{color:var(--gold-dim);text-decoration:none;transition:color .2s,text-shadow .2s}
a:hover{color:var(--gold-bright);text-shadow:0 0 12px var(--gold-dim)}
.skip{position:absolute;left:-999px;top:0}
.skip:focus{left:8px;top:8px;background:var(--card);padding:8px;z-index:2}
header,footer{display:flex;flex-wrap:wrap;gap:10px 16px;align-items:center;justify-content:space-between;max-width:46rem;margin:0 auto}
header{padding:18px 16px;border-bottom:1px solid var(--line)}
footer{padding:24px 16px calc(28px + env(safe-area-inset-bottom));border-top:1px solid var(--line);color:var(--faint);font-size:12px}
nav{display:flex;flex-wrap:wrap;gap:6px 18px}
nav a,nav span,header .links a,footer a{display:inline-flex;align-items:center;min-height:44px;font-family:var(--mono);font-size:11px;letter-spacing:.3em;text-transform:uppercase}
.brand{font-family:var(--display);font-weight:300;letter-spacing:.25em;color:var(--gold);text-shadow:0 0 12px var(--gold-dim),0 0 40px rgba(201,168,76,.25);font-size:1rem;min-height:44px;display:inline-flex;align-items:center;gap:.8em}
.brand small{font-family:var(--mono);font-size:10px;letter-spacing:.4em;color:var(--faint);text-shadow:none;text-transform:uppercase}
main{max-width:46rem;margin:0 auto;padding:16px 16px 40px}
h1{font-family:var(--display);font-weight:300;font-size:clamp(1.5rem,4.5vw,2.1rem);line-height:1.25;letter-spacing:.06em;color:var(--gold);text-shadow:0 0 12px var(--gold-dim),0 0 40px rgba(201,168,76,.2);margin:.3em 0 .5em;text-wrap:balance}
h2{font-family:var(--mono);font-size:12px;font-weight:500;letter-spacing:.3em;text-transform:uppercase;color:var(--faint);margin:0 0 1em}
h3{font-size:1rem;color:var(--ink-2);margin:0 0 .3em}
p,li{overflow-wrap:anywhere}
strong{color:var(--ink);font-weight:600}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:20px;margin:14px 0;transition:border-color .2s}
section:hover{border-color:var(--line-2)}
section#offer{background:transparent;border:0;padding:12px 0 4px}
section#offer p:first-of-type{font-size:1.1rem;color:var(--ink)}
.lead{font-size:1.05rem}
ul,ol{margin:.4em 0;padding-left:1.2em}
li{margin:.35em 0}
li::marker{color:var(--gold-dim)}
blockquote{margin:.6em 0;padding:.2em 0 .2em 14px;border-left:1px solid var(--gold-dim);color:var(--mute)}
code{font-family:var(--mono);font-size:.88em;color:var(--gold-dim)}
mark.placeholder{background:transparent;color:var(--wait);padding:0}
.tier{border:1px solid var(--line);border-radius:10px;padding:14px;margin:10px 0}
.price{font-family:var(--mono);color:var(--gold)}
a.pay,button.pay{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:12px 26px;border-radius:6px;font:500 12px var(--mono);letter-spacing:.3em;text-transform:uppercase;text-decoration:none;border:1px solid var(--gold);background:transparent;color:var(--gold);cursor:pointer;transition:all .2s}
a.pay:hover,button.pay:hover{color:#000;background:var(--gold);box-shadow:0 0 24px var(--gold-dim);text-shadow:none}
a.pay:active,button.pay:active{transform:scale(.98)}
a.pay:visited{color:var(--gold)}
button.pay:disabled{border-color:var(--line-2);color:var(--faint);cursor:not-allowed;box-shadow:none;background:transparent}
.cta{margin:18px 0}
.ticket{font-family:var(--mono);font-size:13px;letter-spacing:.2em;text-transform:uppercase;color:var(--mute)}
.ticket strong{font-family:var(--display);font-size:1.6rem;letter-spacing:.15em;color:var(--gold);text-shadow:0 0 12px var(--gold-dim)}
.ticket::after{content:"";display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--wait);box-shadow:0 0 8px var(--wait);margin-left:.6em;vertical-align:middle;animation:pulse 1s ease-in-out infinite alternate}
@keyframes pulse{from{opacity:.35}to{opacity:1}}
label{display:block;font-family:var(--mono);font-size:11px;font-weight:500;letter-spacing:.2em;text-transform:uppercase;color:var(--mute);margin:18px 0 6px}
input,select,textarea{font:16px/1.5 var(--sans);color:var(--ink);background:var(--void);border:1px solid var(--line-2);border-radius:6px;padding:12px;width:100%;min-height:46px;transition:border-color .2s,box-shadow .2s}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--gold-dim);box-shadow:0 0 0 1px var(--gold-dim),0 0 18px rgba(201,168,76,.15)}
textarea{min-height:8rem;resize:vertical}
.errors{color:var(--warn);padding-left:1.2em}
.hp{position:absolute;left:-10000px;width:1px;height:1px;overflow:hidden}
dl{margin:0}
dt{font-family:var(--mono);font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--faint);margin-top:10px}
dd{margin:0}
article+article{margin-top:16px;padding-top:10px;border-top:1px solid var(--line)}
:focus-visible{outline:1px solid var(--gold);outline-offset:3px}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
`;

function siteLinks(env: Env): string {
  const repo = validHttps(env.REPO_URL);
  const email = validEmail(env.CONTACT_EMAIL);
  const source = repo
    ? `<a href="${escapeHtml(repo)}">Source</a>`
    : `<span>Source <mark class="placeholder">[REPO_URL]</mark></span>`;
  const contact = email
    ? `<a href="mailto:${escapeHtml(email)}">Contact</a>`
    : '';
  return `<a href="https://plan.rgnrk.co">Plan</a>${source}${contact}`;
}

function shell(env: Env, nonce: string, title: string, main: string, robots = ''): string {
  const robot = robots ? `<meta name="robots" content="${escapeHtml(robots)}">` : '';
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
${robot}<title>${escapeHtml(title)}</title>
<style nonce="${nonce}">${STYLE}</style></head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header><a class="brand" href="/">CLR — Rgnrk. <small>fix</small></a><nav class="links" aria-label="Site">${siteLinks(env)}</nav></header>
<main id="main">${main}</main>
<footer><nav aria-label="Footer">${siteLinks(env)}<a href="/welcome">Send a ticket</a></nav></footer>
</body></html>`;
}

function payControl(env: Env, tierId: string): string {
  const bag = env as unknown as Record<string, unknown>;
  const raw = bag[`PAY_URL_${tierId}`];
  const url = validHttps(typeof raw === 'string' ? raw : undefined);
  if (!url) return '<button type="button" class="pay" disabled>Payment link not set yet</button>';
  return `<a class="pay" href="${escapeHtml(url)}">Pay</a>`;
}

function sectionBlock(section: Section, repo: string | null, withStart: boolean): string {
  const id = SECTION_IDS[section.title as SectionTitle];
  const start = withStart ? '<p class="cta"><a class="pay" href="/welcome">Send a ticket</a></p>' : '';
  return `<section id="${id}"><h2>${escapeHtml(section.title)}</h2>${applyRepoUrl(renderMarkdown(section.body), repo)}${start}</section>`;
}

function pricingBlock(copy: Copy, env: Env, repo: string | null): string {
  const { tiers, notes } = parsePricing(sectionByTitle(copy, 'Pricing').body);
  const cards = tiers
    .map(
      (tier) => `<article class="tier"><h3>${inline(tier.name)}</h3><p class="price">${inline(tier.price)}</p><p>${inline(tier.detail)}</p>${payControl(env, tier.id)}</article>`,
    )
    .join('');
  return `<section id="pricing"><h2>Pricing</h2><div class="tiers">${cards}</div>${applyRepoUrl(renderMarkdown(notes), repo)}</section>`;
}

const PAGE_NAV = `<nav aria-label="On this page">
<a href="#offer">Offer</a>
<a href="#pricing">Pricing</a>
<a href="#sample-proof-report">Sample report</a>
<a href="#open-source">Open source</a>
<a href="#faq">FAQ</a>
<a href="/welcome">Send a ticket</a>
</nav>`;

export function homePage(copy: Copy, env: Env, nonce: string): string {
  const repo = validHttps(env.REPO_URL);
  const parts = [PAGE_NAV];
  for (const section of copy.sections) {
    if (section.title === 'Pricing') parts.push(pricingBlock(copy, env, repo));
    else parts.push(sectionBlock(section, repo, section.title === 'Hero'));
  }
  parts.push('<p class="cta"><a class="pay" href="/welcome">Send a ticket</a></p>');
  return shell(env, nonce, `${copy.title} — AI work, done with proof`, parts.join('\n'));
}

function choice(current: string, value: string): string {
  return current.trim() === value ? ' selected' : '';
}

function intakeForm(errors: string[], values: Intake): string {
  const err = errors.length
    ? `<ul class="errors">${errors.map((e) => `<li>${escapeHtml(e)}</li>`).join('')}</ul>`
    : '';
  const v = (key: keyof Intake) => escapeHtml(values[key]);
  return `<form method="post" action="/intake" accept-charset="utf-8">
<h2>Intake</h2>
<p>Your name and email, so I can send the agreement. This form can't take a file. Paste the exact error if you have it.</p>
${err}
<label for="f-name">Name</label>
<input id="f-name" name="name" required maxlength="200" autocomplete="name" value="${v('name')}">
<label for="f-email">Email</label>
<input id="f-email" name="email" type="email" required maxlength="200" autocomplete="email" value="${v('email')}">
<label for="f-trying">What were you trying to do, and what happened instead?</label>
<textarea id="f-trying" name="trying" required maxlength="4000">${v('trying')}</textarea>
<label for="f-last">When did it last work, and what changed since?</label>
<textarea id="f-last" name="last_worked" required maxlength="2000">${v('last_worked')}</textarea>
<label for="f-machine">What machine and system is it?</label>
<input id="f-machine" name="machine" required maxlength="500" value="${v('machine')}">
<label for="f-fixed">What does fixed look like, in one sentence we can test?</label>
<textarea id="f-fixed" name="fixed" required maxlength="1000">${v('fixed')}</textarea>
<label for="f-touch">Is there anything I must not touch or look at?</label>
<textarea id="f-touch" name="dont_touch" maxlength="2000">${v('dont_touch')}</textarea>
<label for="f-backup">Is there a backup?</label>
<select id="f-backup" name="backup" required>
<option value=""${choice(values.backup, '')}>Choose one</option>
<option value="yes"${choice(values.backup, 'yes')}>Yes</option>
<option value="no"${choice(values.backup, 'no')}>No</option>
<option value="not-sure"${choice(values.backup, 'not-sure')}>Not sure</option>
</select>
<label for="f-access">In person or remote?</label>
<select id="f-access" name="access" required>
<option value=""${choice(values.access, '')}>Choose one</option>
<option value="in-person"${choice(values.access, 'in-person')}>In person</option>
<option value="remote"${choice(values.access, 'remote')}>Remote</option>
<option value="not-sure"${choice(values.access, 'not-sure')}>Not sure</option>
</select>
<label for="f-tool">If remote, which tool? Screen share, Chrome Remote Desktop, or RustDesk.</label>
<input id="f-tool" name="access_tool" maxlength="500" value="${v('access_tool')}">
<div class="hp" aria-hidden="true">
<label for="f-hp">Company website</label>
<input id="f-hp" name="company_website" tabindex="-1" autocomplete="off" value="">
</div>
<p class="cta"><button class="pay" type="submit">Send ticket</button></p>
</form>`;
}

export function welcomePage(
  copy: Copy,
  env: Env,
  nonce: string,
  opts: { errors?: string[]; values?: Intake } = {},
): string {
  const steps = renderMarkdown(sectionByTitle(copy, 'Onboarding').body);
  const main = `<section id="onboarding"><h1>Send a ticket</h1>
${steps}
<p>If a payment page sent you here, this site does not check that a payment went through. The next step is still the written agreement. I wait for your "agreed" reply before I touch anything.</p>
${intakeForm(opts.errors ?? [], opts.values ?? EMPTY_INTAKE)}
</section>`;
  return shell(env, nonce, 'Send a ticket — Proved', main);
}

export function thanksPage(env: Env, nonce: string, name: string, ticket = ''): string {
  const who = name ? `, ${escapeHtml(name)}` : '';
  const num = ticket ? `<p class="ticket">Ticket <strong>#${escapeHtml(ticket)}</strong> &middot; Queued</p>` : '';
  const main = `<section><h1>Ticket received</h1>
${num}<p>Thanks${who}. Your ticket is in the queue. You'll get the diagnosis by email: what's wrong and how I know. It's free.</p>
<p>If you want the fix after that, a one-time fix is $50 (bigger pipeline fixes run upwards of ~$200), and nothing gets touched until you reply "agreed". Keep your ticket number in case you need to ask about it.</p>
<p><a href="/">Back to the offer</a></p></section>`;
  return shell(env, nonce, 'Ticket received — Proved', main);
}

export function messagePage(env: Env, nonce: string, heading: string, message: string): string {
  const main = `<section><h1>${escapeHtml(heading)}</h1><p>${escapeHtml(message)}</p>
<p><a href="/welcome">Back to the ticket form</a></p></section>`;
  return shell(env, nonce, `${heading} — Proved`, main);
}

const INTAKE_LABELS: Record<string, string> = {
  at: 'Received',
  ticket: 'Ticket',
  name: 'Name',
  email: 'Email',
  trying: 'What happened',
  last_worked: 'When it last worked',
  machine: 'Machine',
  fixed: 'Fixed looks like',
  dont_touch: 'Do not touch',
  backup: 'Backup',
  access: 'Access',
  access_tool: 'Remote tool',
};

function recordHtml(row: StoredIntake): string {
  let fields: Record<string, string> | null = null;
  try {
    const parsed = JSON.parse(row.raw) as unknown;
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      fields = {};
      for (const [key, value] of Object.entries(parsed)) {
        if (typeof value === 'string') fields[key] = value;
      }
    }
  } catch {
    fields = null;
  }
  if (!fields) {
    return `<article><h2>${escapeHtml(row.key)}</h2><pre>${escapeHtml(row.raw)}</pre></article>`;
  }
  const body = Object.entries(fields)
    .map(([key, value]) => `<dt>${escapeHtml(INTAKE_LABELS[key] ?? key)}</dt><dd>${escapeHtml(value)}</dd>`)
    .join('');
  return `<article><h2>${escapeHtml(row.key)}</h2><dl>${body}</dl></article>`;
}

export function adminPage(env: Env, nonce: string, rows: StoredIntake[]): string {
  const list = rows.length ? rows.map(recordHtml).join('') : '<p>No intakes yet.</p>';
  const main = `<section><h1>Intakes</h1>${list}</section>`;
  return shell(env, nonce, 'Intakes — Proved', main, 'noindex');
}
