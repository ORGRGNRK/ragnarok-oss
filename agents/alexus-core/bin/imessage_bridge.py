#!/usr/bin/env python3
"""
iMessage Bridge for Alexus.

Monitors ~/Library/Messages/chat.db for incoming messages, passes relevant
prompts to the local Ollama LLM endpoint, and dispatches responses back
to the matching message thread via AppleScript.
"""

import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    from . import ragnarok_bridge
except ImportError:
    import ragnarok_bridge

CHAT_DB = os.path.expanduser("~/Library/Messages/chat.db")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://alexus:11434")
POLL_INTERVAL_SECONDS = 1.5


def check_full_disk_access():
    """Checks if ~/Library/Messages/chat.db is accessible."""
    try:
        if not os.path.exists(CHAT_DB):
            return False
        conn = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
        cur = conn.cursor()
        cur.execute("SELECT count(*) FROM message LIMIT 1;")
        cur.fetchone()
        conn.close()
        return True
    except Exception:
        return False


def send_imessage(recipient, text):
    """Sends an iMessage to a recipient (phone number, email, or chat id) via AppleScript."""
    clean_text = text.replace('\\', '\\\\').replace('"', '\\"').replace("'", "'\\''")
    script = f'''
    set recipient to "{recipient}"
    set msgText to "{clean_text}"
    tell application "Messages"
        try
            set targetBuddy to participant recipient
            send msgText to targetBuddy
            return "SENT_BUDDY"
        on error
            try
                set targetChat to chat id recipient
                send msgText to targetChat
                return "SENT_CHAT"
            on error errStr
                return "ERROR: " & errStr
            end try
        end try
    end tell
    '''
    try:
        res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
        return res.stdout.strip()
    except Exception as e:
        return f"EXEC_ERROR: {e}"


def clean_ansi(text):
    """Strips terminal color codes from output."""
    ansi_regex = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_regex.sub('', text)


def generate_reply(incoming_text, sender_handle=None):
    """Runs incoming message through Alexus chat inference with persona and boot context."""
    profile = ragnarok_bridge.load_profile() or {
        "user_name": ragnarok_bridge.owner_name(),
        "persona_id": "tsundere"
    }
    system_prompt = ragnarok_bridge.get_system_prompt_for_profile(profile)
    boot_context = ragnarok_bridge.silent_boot(project_slug="alexus-core")

    cleaned_input = re.sub(r'^(?:!alexus|alexus:?|hey alexus:?)\s*', '', incoming_text, flags=re.IGNORECASE).strip()
    if not cleaned_input:
        cleaned_input = "Hello"

    messages = [
        {
            "role": "system",
            "content": (
                f"{system_prompt}\n\n{boot_context}\n"
                "[NOTE: You are replying over SMS/iMessage. Keep the response punchy, "
                "concise, under 3-4 sentences, and in character.]"
            )
        },
        {"role": "user", "content": cleaned_input}
    ]

    try:
        url = f"{OLLAMA_HOST}/api/chat"
        data = json.dumps({"model": "llama3.2:3b", "messages": messages, "stream": False}).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            res = json.loads(r.read().decode("utf-8"))
            reply = res.get("message", {}).get("content", "").strip()
            return clean_ansi(reply)
    except Exception as e:
        return f"[Alexus Core Offline: {e}]"


def cmd_imessage_daemon():
    """Runs background daemon listening on chat.db for incoming iMessages."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    if not check_full_disk_access():
        sys.stderr.write("Error: Full Disk Access is required to read ~/Library/Messages/chat.db.\n")
        sys.stderr.write("Grant access to Terminal/Python in System Settings > Privacy & Security > Full Disk Access.\n")
        sys.exit(1)

    logging.info("Starting iMessage daemon (poll interval: %.1fs)", POLL_INTERVAL_SECONDS)
    logging.info("Connected to chat database at %s", CHAT_DB)

    conn = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
    cur = conn.cursor()
    cur.execute("SELECT max(ROWID) FROM message;")
    row = cur.fetchone()
    last_rowid = row[0] if (row and row[0]) else 0
    conn.close()

    logging.info("Baseline initialized at message ROWID #%d. Polling for messages...", last_rowid)

    while True:
        try:
            time.sleep(POLL_INTERVAL_SECONDS)
            conn = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
            cur = conn.cursor()

            query = """
            SELECT 
                m.ROWID, 
                m.text, 
                COALESCE(h.id, 'Self'), 
                m.is_from_me,
                c.guid
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > ? AND m.text IS NOT NULL
            ORDER BY m.ROWID ASC;
            """
            cur.execute(query, (last_rowid,))
            rows = cur.fetchall()
            conn.close()

            for msg_id, text, sender, is_from_me, chat_guid in rows:
                last_rowid = max(last_rowid, msg_id)
                text = text.strip() if text else ""
                if not text:
                    continue

                is_trigger = False
                if is_from_me == 0 and ("alexus" in text.lower() or text.startswith("!")):
                    is_trigger = True
                elif is_from_me == 1 and (text.lower().startswith("!alexus") or text.lower().startswith("alexus:")):
                    is_trigger = True

                if is_trigger:
                    logging.info("Received trigger message #%d from [%s]: '%s'", msg_id, sender, text)
                    reply = generate_reply(text, sender_handle=sender)
                    logging.info("Generated reply: '%s'", reply)

                    target_recip = chat_guid or (sender if sender != "Self" else None)
                    if target_recip:
                        send_res = send_imessage(target_recip, reply)
                        logging.info("Delivery status to %s: %s", target_recip, send_res)
                    else:
                        logging.warning("Could not resolve destination chat GUID for message #%d", msg_id)

        except KeyboardInterrupt:
            logging.info("iMessage daemon stopped by user.")
            break
        except Exception as err:
            logging.exception("Error in iMessage loop: %s", err)
            time.sleep(2)


def cmd_imessage_reply(incoming_text, sender_handle="me"):
    """One-shot command to generate and send an iMessage reply."""
    reply = generate_reply(incoming_text, sender_handle=sender_handle)
    if sender_handle and sender_handle != "me":
        res = send_imessage(sender_handle, reply)
        print(f"Delivery: {res}")
    return reply


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "daemon":
        cmd_imessage_daemon()
    elif len(sys.argv) > 2 and sys.argv[1] == "reply":
        cmd_imessage_reply(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "me")
    else:
        print("Usage: imessage_bridge.py [daemon | reply <text> <sender>]")
