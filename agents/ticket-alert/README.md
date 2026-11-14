# Ticket Alert

Texts the owner when a new ticket lands on fix.rgnrk.co. The site only stores a ticket in Cloudflare KV;
this is the only thing that tells him one arrived.

Every 5 minutes launchd (`co.rgnrk.ticket-alert`, copy in ~/Library/LaunchAgents) runs `ticket-alert.py`.
It lists the `intake:` keys with the wrangler login in `~/Developer/proved-site` (read only) and iMessages
each new one, "Alexus · Ticket #… from …: …", to the handle in `../upwork-alert/config`.

- A ticket is marked seen only after its text was sent.
- Three failed checks in a row send one "Ticket check is failing" text. It texts again when it recovers.
- It needs this Mac awake and the wrangler login still valid. If wrangler is logged out, run
  `npx wrangler login` in `~/Developer/proved-site`.
- State: `~/.ragnarok/ticket-alert/state.json`. Log: `~/Library/Logs/ticket-alert.log` (ticket numbers only).

Check: `python3 ticket-alert.py selfcheck` (fake site, fake phone, no text sent).
Turn off: `launchctl bootout gui/$(id -u)/co.rgnrk.ticket-alert` and delete the plist from ~/Library/LaunchAgents.
