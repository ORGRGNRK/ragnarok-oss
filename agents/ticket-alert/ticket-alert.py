#!/usr/bin/env python3
"""Ticket Alert: text the owner when a new ticket lands on fix.rgnrk.co.

The site only stores a ticket in Cloudflare KV. Nothing told the owner one arrived. Every 5 minutes launchd
(co.rgnrk.ticket-alert) runs this. It lists the `intake:` keys with the site repo's own wrangler login
(read only), and iMessages each new one to the same handle Upwork Alert uses (../upwork-alert/config).

  ticket-alert.py            one check
  ticket-alert.py selfcheck  prove the logic with a fake site and a fake phone (no network, no text sent)

Rules: a ticket is marked seen only after its text was sent. The first run sends one count, not one text per
old ticket. Three failed checks in a row send one "check is failing" text, so silence is never read as "no
tickets". Ticket text is untrusted data: it is passed to Messages as an argument, never as script.
State: ~/.ragnarok/ticket-alert/state.json. Log (ticket numbers only): ~/Library/Logs/ticket-alert.log
"""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
SITE = Path(os.environ.get('TICKET_ALERT_SITE', Path.home() / 'Developer/proved-site'))
STATE = Path(os.environ.get('TICKET_ALERT_STATE', Path.home() / '.ragnarok/ticket-alert'))
LOG = Path(os.environ.get('TICKET_ALERT_LOG', Path.home() / 'Library/Logs/ticket-alert.log'))
RECIPIENT_FILE = HERE.parent / 'upwork-alert/config'
MAX_TEXTS = 5          # per run; more than this is summed up in one line
FAILS_BEFORE_TEXT = 3
SEND = ('on run argv\ntell application "Messages"\nset svc to 1st account whose service type = iMessage\n'
        'send (item 2 of argv) to participant (item 1 of argv) of svc\nend tell\nend run')


def log(text):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('a') as f:
        f.write('%s %s\n' % (datetime.datetime.now().strftime('%F %T'), text))


def namespace():
    """The KV id is read from the site's own config at run time, so a changed id needs no edit here."""
    m = re.search(r'binding\s*=\s*"SITE_KV"\s*\n\s*id\s*=\s*"([0-9a-f]{32})"', (SITE / 'wrangler.toml').read_text())
    if not m:
        raise RuntimeError('SITE_KV id not found in wrangler.toml')
    return m.group(1)


def wrangler(*args):
    fake = os.environ.get('TICKET_ALERT_WRANGLER')
    cmd = [fake, *args] if fake else ['npx', '--no-install', 'wrangler', 'kv', 'key', *args,
                                      '--namespace-id', namespace(), '--remote']
    r = subprocess.run(cmd, cwd=SITE, capture_output=True, text=True, timeout=90)
    if r.returncode:
        raise RuntimeError('wrangler exited %d' % r.returncode)
    return r.stdout


def list_keys():
    out = wrangler('list', '--prefix', 'intake:')
    rows = json.loads(out[out.index('['):])
    return sorted(row['name'] for row in rows if isinstance(row.get('name'), str))


def ticket_line(key):
    """One short line for the text. A ticket that will not parse still gets a text, with its number."""
    number = key.rsplit(':', 1)[-1]
    try:
        out = wrangler('get', key, '--text')
        t = json.loads(out[out.index('{'):out.rindex('}') + 1])
        name = ' '.join(str(t.get('name', '')).split())[:40]
        what = ' '.join(str(t.get('trying', '')).split())[:140]
        return 'Alexus · Ticket #%s from %s: %s' % (t.get('ticket') or number, name or 'unknown', what or '(no text)')
    except (RuntimeError, ValueError, subprocess.TimeoutExpired):
        return 'Alexus · Ticket #%s arrived (could not read it; see /admin/intakes)' % number


def send(text):
    fake = os.environ.get('TICKET_ALERT_SEND')
    if fake:
        return subprocess.run([fake, text], timeout=30).returncode == 0
    m = re.search(r'^RECIPIENT=(.+)$', RECIPIENT_FILE.read_text(), re.M)
    if not m:
        raise RuntimeError('no RECIPIENT in upwork-alert/config')
    r = subprocess.run(['/usr/bin/osascript', '-e', SEND, m.group(1).strip(), text],
                       capture_output=True, text=True, timeout=60)
    return r.returncode == 0


def load():
    try:
        return json.loads((STATE / 'state.json').read_text())
    except (OSError, ValueError):
        return None


def save(state):
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = STATE / 'state.json.tmp'
    tmp.write_text(json.dumps(state, indent=1) + '\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE / 'state.json')


def check():
    state = load()
    first = state is None
    state = state or {'seen': [], 'fails': 0}
    try:
        keys = list_keys()
    except Exception as e:   # the reason goes to the log; the text only says the check is failing
        state['fails'] = state.get('fails', 0) + 1
        log('check failed (%d in a row): %s' % (state['fails'], type(e).__name__ + ' ' + str(e)[:120]))
        if state['fails'] == FAILS_BEFORE_TEXT and not first:
            send('Alexus · Ticket check is failing. New tickets on fix.rgnrk.co are NOT being texted. See ~/Library/Logs/ticket-alert.log')
        if not first:
            save(state)
        return 1
    if state.get('fails', 0) >= FAILS_BEFORE_TEXT:
        send('Alexus · Ticket check is working again.')
    state['fails'] = 0
    seen = set(state['seen'])
    new = [k for k in keys if k not in seen]
    if first:
        if not new or send('Alexus · Ticket alert is on. %d ticket%s already waiting on fix.rgnrk.co.'
                           % (len(new), '' if len(new) == 1 else 's')):
            state['seen'] = keys
            save(state)
            log('first run: %d existing' % len(new))
            return 0
        log('first run: could not send the text')
        return 1
    rc = 0
    for key in new[:MAX_TEXTS]:
        if send(ticket_line(key)):
            state['seen'].append(key)
            log('texted ticket ' + key.rsplit(':', 1)[-1])
        else:
            log('could not send the text for ticket ' + key.rsplit(':', 1)[-1] + '; will try again')
            rc = 1
            break
    rest = new[MAX_TEXTS:]
    if rest and rc == 0 and send('Alexus · and %d more new tickets on fix.rgnrk.co (see /admin/intakes)' % len(rest)):
        state['seen'] += rest
        log('summed up %d more' % len(rest))
    save(state)
    return rc


def selfcheck():
    """Fake site, fake phone. Proves: first-run count, one text per new ticket, no repeat, retry after a failed
    send, untrusted text passed as data, a cap per run, and one text when the check itself keeps failing."""
    with tempfile.TemporaryDirectory(prefix='ticket-alert-check-') as tmp:
        tmp = Path(tmp)
        store, sent, mode = tmp / 'store.json', tmp / 'sent.txt', tmp / 'mode'
        fake_w = tmp / 'wrangler'
        fake_w.write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                          'if Path(%r).read_text()=="down": sys.exit(1)\n'
                          'd=json.loads(Path(%r).read_text())\n'
                          'if sys.argv[1]=="list": print("banner line\\n"+json.dumps([{"name":k} for k in d]))\n'
                          'else: print(d[sys.argv[2]])\n' % (str(mode), str(store)))
        fake_s = tmp / 'send'
        fake_s.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n'
                          'if Path(%r).read_text()=="nosend": sys.exit(1)\n'
                          'open(%r,"a").write(sys.argv[1]+"\\n")\n' % (str(mode), str(sent)))
        for f in (fake_w, fake_s):
            f.chmod(0o755)
        os.environ.update(TICKET_ALERT_WRANGLER=str(fake_w), TICKET_ALERT_SEND=str(fake_s))
        global STATE, LOG
        STATE, LOG = tmp / 'state', tmp / 'log'
        tickets = {}

        def put(n, **kw):
            tickets['intake:%d:T%d' % (n, n)] = json.dumps({'ticket': 'T%d' % n, 'name': 'Ada', 'trying': 'it broke', **kw})
            store.write_text(json.dumps(tickets))

        def texts():
            return sent.read_text().splitlines() if sent.exists() else []
        ok = []
        mode.write_text('up'); put(1); put(2)
        ok.append(('first run sends one count', check() == 0 and texts() == ['Alexus · Ticket alert is on. 2 tickets already waiting on fix.rgnrk.co.']))
        ok.append(('nothing new sends nothing', check() == 0 and len(texts()) == 1))
        put(3, trying='"; do shell script "rm -rf ~" --\nline two')
        ok.append(('a new ticket is texted once, as data', check() == 0 and check() == 0 and texts()[1:] == ['Alexus · Ticket #T3 from Ada: "; do shell script "rm -rf ~" -- line two']))
        put(4); mode.write_text('nosend')
        ok.append(('a failed send is not marked seen', check() == 1 and len(texts()) == 2))
        mode.write_text('up')
        ok.append(('and is sent on the next run', check() == 0 and texts()[-1].startswith('Alexus · Ticket #T4 ')))
        tickets['intake:5:T5'] = 'not json'; store.write_text(json.dumps(tickets))
        ok.append(('an unreadable ticket still texts its number', check() == 0 and '#T5 arrived' in texts()[-1]))
        for n in range(6, 14):
            put(n)
        before = len(texts())
        ok.append(('a flood is capped', check() == 0 and len(texts()) == before + MAX_TEXTS + 1 and 'and 3 more' in texts()[-1] and check() == 0 and len(texts()) == before + MAX_TEXTS + 1))
        mode.write_text('down'); before = len(texts())
        codes = [check() for _ in range(5)]
        ok.append(('a failing check texts once', codes == [1] * 5 and len(texts()) == before + 1 and 'NOT being texted' in texts()[-1]))
        mode.write_text('up')
        ok.append(('and says when it works again', check() == 0 and texts()[-1] == 'Alexus · Ticket check is working again.'))
        for name, good in ok:
            print(('ok   ' if good else 'FAIL ') + name)
        return 0 if all(g for _, g in ok) else 1


if __name__ == '__main__':
    sys.exit(selfcheck() if sys.argv[1:] == ['selfcheck'] else check())
