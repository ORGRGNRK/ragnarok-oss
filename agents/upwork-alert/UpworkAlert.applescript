-- Upwork Alert: Mail rule script.
-- For each matching message: one-line summary via local Qwen (Alexus), then iMessage to own handle.
on expandedBase()
	return (POSIX path of (path to home folder)) & "Developer/upwork-alert"
end expandedBase

on readRecipient()
	set cfg to expandedBase() & "/config"
	return do shell script "/usr/bin/sed -n 's/^RECIPIENT=//p' " & quoted form of cfg & " | /usr/bin/head -n 1"
end readRecipient

on logLine(t)
	try
		do shell script "printf '%s %s\\n' \"$(date '+%F %T')\" " & quoted form of t & " >> ~/Library/Logs/upwork-alert.log"
	end try
end logLine

on summarizeMessage(theSender, theSubject, theBody)
	set tmpPath to do shell script "/usr/bin/mktemp -t upworkalert"
	try
		set fh to open for access (POSIX file tmpPath) with write permission
		set eof of fh to 0
		write ("Subject: " & theSubject & linefeed & "From: " & theSender & linefeed & linefeed & theBody) to fh as «class utf8»
		close access fh
	on error
		try
			close access (POSIX file tmpPath)
		end try
	end try
	set summaryLine to ""
	try
		set summaryLine to do shell script "/bin/bash " & quoted form of (expandedBase() & "/summarize.sh") & " " & quoted form of tmpPath
	end try
	do shell script "/bin/rm -f " & quoted form of tmpPath
	if summaryLine is "" then set summaryLine to theSubject
	return summaryLine
end summarizeMessage

on sendSelf(theText)
	set theHandle to readRecipient()
	tell application "Messages"
		set svc to 1st account whose service type = iMessage
		send theText to participant theHandle of svc
	end tell
end sendSelf

-- Verification check: returns "" if not a code/verify email, else "VERIFY<tab><code>".
on verifyInfo(theSender, theSubject, theContent)
	set tmpPath to do shell script "/usr/bin/mktemp -t upworkverify"
	try
		set fh to open for access (POSIX file tmpPath) with write permission
		set eof of fh to 0
		write ("Subject: " & theSubject & linefeed & "From: " & theSender & linefeed & linefeed & theContent) to fh as «class utf8»
		close access fh
	on error
		try
			close access (POSIX file tmpPath)
		end try
	end try
	set r to ""
	try
		set r to do shell script "/bin/bash " & quoted form of (expandedBase() & "/extract-code.sh") & " " & quoted form of tmpPath
	end try
	do shell script "/bin/rm -f " & quoted form of tmpPath
	return r
end verifyInfo

on processMessage(theSender, theSubject, theContent)
	if (length of theContent) > 3000 then set theContent to text 1 thru 3000 of theContent
	-- Mail hands rule scripts every message in the batch, not only matches, so filter here.
	if theSender contains "upwork.com" then
		set c to theContent
		if (length of c) > 1500 then set c to text 1 thru 1500 of c
		set s to my summarizeMessage(theSender, theSubject, c)
		my sendSelf("Alexus · Upwork: " & s)
		my logLine("sent upwork alert for subject: " & theSubject)
		return
	end if
	set v to my verifyInfo(theSender, theSubject, theContent)
	if v starts with "VERIFY" then
		set AppleScript's text item delimiters to tab
		set theCode to ""
		try
			set theCode to text item 2 of v
		end try
		set AppleScript's text item delimiters to ""
		set fromName to theSender
		if fromName contains "<" then set fromName to text 1 thru ((offset of "<" in fromName) - 1) of fromName
		if theCode is "" then
			my sendSelf("Alexus · Verify: " & fromName & "— " & theSubject)
		else
			my sendSelf("Alexus · Code " & theCode & " from " & fromName & "— " & theSubject)
		end if
		my logLine("sent verify alert for subject: " & theSubject)
		return
	end if
	my logLine("skipped (not upwork/verify): " & theSubject)
end processMessage

using terms from application "Mail"
	on perform mail action with messages theMessages for rule theRule
		repeat with m in theMessages
			try
				tell application "Mail"
					set theSender to sender of m
					set theSubject to subject of m
					set theContent to ""
					try
						set theContent to content of m
					end try
				end tell
				my processMessage(theSender, theSubject, theContent)
			on error errMsg
				my logLine("error: " & errMsg)
				try
					my logLine("fallback skipped send for: " & theSubject)
				end try
			end try
		end repeat
	end perform mail action with messages
end using terms from

-- Manual test: osascript -e 'set s to load script POSIX file "<path>/UpworkAlert.scpt"' -e 'tell s to processMessage("sender","subject","body")'
