# Upwork Alert

Mail rule "Upwork Alert" (From contains upwork.com) runs
`~/Library/Application Scripts/com.apple.mail/UpworkAlert.scpt` (compiled from UpworkAlert.applescript).
For each message it writes subject/sender/first 1500 chars to a temp file, runs `summarize.sh`
(Ollama on Alexus over Tailscale, model from `config`, 20s timeout, falls back to the subject),
and iMessages "Upwork: <line>" to your own iMessage handle (stored in `config`, chmod 600, git-ignored).
Log: ~/Library/Logs/upwork-alert.log

Rebuild script: `osacompile -o ~/Library/Application\ Scripts/com.apple.mail/UpworkAlert.scpt UpworkAlert.applescript`

LaunchAgents (copies in ~/Library/LaunchAgents):
- co.rgnrk.upwork-alert-awake: `caffeinate -s` (no system sleep while on AC power), KeepAlive
- co.rgnrk.upwork-alert-mail: `open -g -a Mail` at login

Turn off:
- Mail > Settings > Rules > uncheck "Upwork Alert" (or:
  `osascript -e 'tell application "Mail" to set enabled of rule "Upwork Alert" to false'`)
- `launchctl bootout gui/$(id -u)/co.rgnrk.upwork-alert-awake`
  `launchctl bootout gui/$(id -u)/co.rgnrk.upwork-alert-mail`
  and delete the two plists from ~/Library/LaunchAgents to stop them at next login.
