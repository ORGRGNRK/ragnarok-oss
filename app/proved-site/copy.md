# Proved

## Hero

Something broken? Send a ticket. The diagnosis is free.

Tell me what's broken: your code, your computer, an app, a setup that stopped working. You get back what's wrong, in plain words, and how I know. That costs nothing.

If you want it fixed, a one-time fix is $50. Bigger pipeline fixes run upwards of ~$200. Nothing on your side gets touched until you reply "agreed".

## What you get

- **A free diagnosis.** What's actually wrong, in plain words, with the evidence that shows it. Not a guess.
- **A ticket number** the moment you send it, so you know it arrived.
- **The fix, if you want it: $50 for a one-time fix.** Bigger pipeline fixes run upwards of ~$200. A short agreement first: the job in one sentence, the one thing we'll test at the end, and the price. Reply "agreed" and the work starts. Nothing starts before that.
- AI tools (like Claude) help me diagnose and fix. I check every change and test that it actually works before calling it done.
- I won't delete anything, install anything, or touch accounts and passwords without asking you first.
- Your passwords stay yours. You type them. I don't write them down.
- A log of every change. Each entry carries a fingerprint of the one before it, so an edit or a delete shows up when the log is checked. One limit: someone with full control of the machine could rewrite the whole log, which is why the last fingerprint goes in your report.
- A backup of a file before I change it, saved next to the original, ending in `.bak-YYYY-MM-DD`.
- A short report at the end: what was wrong, what I changed, how it was checked, and anything still open.

## How it works

1. You send a ticket on the form. It's free.
2. You get a ticket number right away.
3. I look into it and send you the diagnosis: what's wrong and how I know. Free, whether or not you want the fix.
4. If you want it fixed, I send a short agreement: the job, the test that proves it's done, and the price ($50 for a one-time fix, upwards of ~$200 for a bigger pipeline fix). You reply "agreed".
5. The work is one change at a time. Each change is tested, then logged with how it was checked. A log entry can only be OK, FAILED, or NOT VERIFIED.
6. If the job turns out bigger than agreed, I stop and tell you before doing more.
7. We run the agreed test, with you watching if we can.
8. You get the proof report, and I remove any access I had.

## Onboarding

1. **Send the ticket.** What were you trying to do, and what happened instead? (The exact error message or a screenshot helps.) When did it last work, and what changed since? What machine and system is it? What does "fixed" look like, in one sentence we can test? Is there anything I must not touch or look at? Is there a backup?
2. **Get the diagnosis.** Free. You decide from there.
3. **Want the fix? Agree the job.** Reply "agreed" to the short agreement. Nothing starts before that.
4. **Set up access, only if the fix needs it.** In person around Your City, ST, or remote. If remote, we pick the tool (screen share, Chrome Remote Desktop, or RustDesk). You can end a remote session at any time. You type any passwords.

## Pricing

- **Diagnosis: free.** What's wrong and how I know, for any ticket.
- **One-time fix: $50.** One job with a written agreement, the change log, a backup of each file that's changed, and the proof report.
- **Bigger pipeline fixes: upwards of ~$200.** A job that runs across several connected steps or tools. The price is in the agreement before anything starts.

If the job turns out bigger than one fix, I tell you before doing more, and you decide.

If the fix doesn't pass the test we agreed on, you don't pay. Some problems (like a physically damaged drive) can't be fixed remotely. If that's the case, I tell you as soon as I know.

You pay after the diagnosis, only if you want the fix. The agreement says how.

## Sample proof report

This is the report template every job uses (`templates/report.md` in the client kit). The bracketed parts are filled in for that job. This is not a report from a finished job.

> **What was wrong**
> The actual cause, in plain words. Example from the template: "The connector couldn't start because the config pointed to a folder that had been renamed."
>
> **What I changed**
> The table from the change log, including its last line with the fingerprint.
> Backups of every file I changed are saved next to the original, ending in `.bak-[date]`. They're safe to delete once you're happy.
>
> **How it was verified**
> What we tested at the end, and the result. Example from the template: "Restarted the app, the 6 tools showed up, and a live lookup returned your latest record."
>
> **Still open / what to do next**
> Anything unknown, or a recommendation. Example from the template: "An API key was visible in an old log file. Please create a new one and delete the old one." Or: "Nothing open."

The template ends with a short thank-you and a name line.

The change table is what `tools/audit.py report` prints. Its columns are: When, Change, File / command, How it was checked, Result. Under the table it prints how many changes were logged, how many were not OK, whether the audit log is intact, and the fingerprint of the last entry.

## Open source

The tool behind the proof is open source. It's called Alexus. It runs AI coding agents (Claude Code, Grok, Codex) and doesn't take the AI's word that a job is done.

The agent writes a checklist. Every line carries a command that proves it. When the agent says it's finished, Alexus runs those commands itself. A failed check goes back to the agent with the output. A run ends as proved, needs you, or dead end.

Every step goes into a hash-chained receipt log. If anyone edits a receipt afterward, the check names the line.

Source: [REPO_URL]

## FAQ

**Do you see or keep my data?**

I only look at what the job needs. Don't put passwords in a ticket. You type your own passwords, and I don't write them down.

**How do you get onto my computer?**

In person, or remotely with screen share, Chrome Remote Desktop, or RustDesk. If I'm connected remotely, you can end the session at any time, and I remove my access when we're done.

**What if it can't be fixed?**

If the job turns out bigger than agreed, I stop and tell you before doing more. Some problems (like a physically damaged drive) can't be fixed remotely. If that's the case, I tell you as soon as I know, and you won't pay for work that can't be done.

**Will you change anything without asking?**

I won't delete anything, install anything, or touch accounts and passwords without asking you first. The job rules also tell the AI to ask before sending anything to an outside service.

**Who owns the work?**

You do. The fix and the report are yours to keep.

**Can I cancel?**

Yes. The diagnosis is free and you can say no to the fix. You can end a remote session at any time. If the fix doesn't pass the agreed test, you don't pay.
