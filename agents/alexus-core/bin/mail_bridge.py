#!/usr/bin/env python3
"""
IMAP/SMTP Mail Bridge for Alexus.

Polls an IMAP mailbox on a configured timer (default: 3 seconds) for
incoming messages addressed to Alexus, queries the local inference endpoint,
and dispatches replies via SMTP with RFC-compliant In-Reply-To and References
threading headers.
"""

import email
from email.message import EmailMessage
from email.utils import parseaddr
import imaplib
import json
import logging
import os
import re
import smtplib
import ssl
import sys
import time
import urllib.error
import urllib.request

try:
    from . import ragnarok_bridge
except ImportError:
    import ragnarok_bridge

CONFIG_PATH = os.path.expanduser("~/.alexus/mail_config.json")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://alexus:11434")
POLL_INTERVAL_SECONDS = 3


def load_config():
    """
    Loads mail bridge configuration from CONFIG_PATH.
    Returns None if the file does not exist.
    Raises json.JSONDecodeError or OSError if the file exists but cannot be parsed.
    """
    if not os.path.exists(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Corrupted JSON in config file {CONFIG_PATH}: {err}\n")
        raise
    except OSError as err:
        sys.stderr.write(f"Error: Unable to read config file {CONFIG_PATH}: {err}\n")
        raise


def save_config(cfg):
    """
    Saves configuration atomically with 0600 file permissions from creation.
    Avoids permission race conditions where the file is world-readable before chmod.
    """
    config_dir = os.path.dirname(CONFIG_PATH)
    os.makedirs(config_dir, mode=0o700, exist_ok=True)

    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(CONFIG_PATH, flags, 0o600)
    with open(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def cmd_mail_setup():
    """Interactive CLI setup for IMAP/SMTP credentials."""
    print("\n--- Alexus Mail Configuration (iCloud IMAP/SMTP) ---")

    current = {}
    if os.path.exists(CONFIG_PATH):
        try:
            current = load_config() or {}
        except Exception as e:
            sys.stderr.write(f"Warning: Existing config file at {CONFIG_PATH} is corrupted: {e}\n")
            proceed = input("Overwrite corrupted configuration? [y/N]: ").strip().lower()
            if proceed != "y":
                print("Setup cancelled. Existing file left intact.")
                sys.exit(1)
            current = {}

    default_email = current.get("email", "")
    email_addr = input(f"Alexus Email Address [{default_email}]: ").strip() or default_email
    while not email_addr:
        email_addr = input("Alexus Email Address (the inbox Alexus reads, e.g. alexus@yourdomain.com): ").strip()

    default_user = current.get("username", "")
    username = input(f"iCloud / Apple ID Username [{default_user}]: ").strip()
    if not username:
        username = default_user

    print("\nApple App-Specific Password Setup:")
    print("  1. Sign in to https://appleid.apple.com")
    print("  2. Open Sign-In and Security > App-Specific Passwords")
    print("  3. Generate a password labeled 'Alexus' (e.g. abcd-efgh-ijkl-mnop)\n")

    password = input("Apple App-Specific Password: ").strip()
    if not password:
        password = current.get("password", "")

    default_sender = current.get("authorized_sender", "")
    auth_sender = input(f"Authorized Personal Email [{default_sender}]: ").strip()
    if not auth_sender:
        auth_sender = default_sender

    cfg = {
        "email": email_addr,
        "imap_server": "imap.mail.me.com",
        "imap_port": 993,
        "smtp_server": "smtp.mail.me.com",
        "smtp_port": 587,
        "username": username,
        "password": password,
        "authorized_sender": auth_sender.lower()
    }
    save_config(cfg)
    print(f"\nConfiguration saved securely to {CONFIG_PATH} (mode 0600).\n")


def clean_email_body(raw_text):
    """Strips quoted replies (e.g. 'On ... wrote:', '> ...') to isolate the new query."""
    lines = raw_text.splitlines()
    clean_lines = []
    for l in lines:
        if l.strip().startswith(">"):
            continue
        if re.match(r"^on\s+.*wrote:?$", l.strip(), re.IGNORECASE):
            break
        clean_lines.append(l)
    return "\n".join(clean_lines).strip()


def send_reply_email(cfg, to_addr, orig_subject, orig_msg_id, reply_text):
    """
    Sends an email reply via SMTP with In-Reply-To and References headers.
    Falls back across allowed senders if Apple SMTP rejects a custom domain sender.
    """
    senders = [cfg["email"]] + [e.strip() for e in ragnarok_bridge._local_conf("OWNER_EMAILS").split(",") if e.strip()] + [cfg["username"]]
    last_err = None

    for from_addr in senders:
        try:
            msg = EmailMessage()
            msg["From"] = f"Alexus <{from_addr}>"
            msg["To"] = to_addr

            subject = orig_subject.strip() if orig_subject else "Alexus Chat"
            if not subject.lower().startswith("re:"):
                subject = f"Re: {subject}"
            msg["Subject"] = subject

            if orig_msg_id:
                msg["In-Reply-To"] = orig_msg_id
                msg["References"] = orig_msg_id

            msg.set_content(reply_text)

            ctx = ssl.create_default_context()
            with smtplib.SMTP(cfg["smtp_server"], cfg["smtp_port"], timeout=15) as s:
                s.starttls(context=ctx)
                s.login(cfg["username"], cfg["password"])
                s.send_message(msg)
            return from_addr
        except smtplib.SMTPSenderRefused as err:
            last_err = err
            continue

    if last_err:
        raise last_err


def cmd_mail_daemon():
    """Runs the IMAP polling listener daemon."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    try:
        cfg = load_config()
    except Exception:
        sys.exit(1)

    if not cfg or not cfg.get("password"):
        logging.error("Email bridge is not configured. Run './alexus mail-setup' first.")
        sys.exit(1)

    logging.info("Starting Alexus mail daemon (poll interval: %ds)", POLL_INTERVAL_SECONDS)
    logging.info("IMAP: %s:%s, SMTP: %s:%s", cfg["imap_server"], cfg["imap_port"], cfg["smtp_server"], cfg["smtp_port"])
    logging.info("Account: %s (address: %s)", cfg["username"], cfg["email"])

    profile = ragnarok_bridge.load_profile() or {"user_name": ragnarok_bridge.owner_name(), "persona_id": "tsundere"}
    system_prompt = ragnarok_bridge.get_system_prompt_for_profile(profile)
    boot_context = ragnarok_bridge.silent_boot(project_slug="alexus-core")

    # Initialize baseline UID to process only new messages arriving after startup
    ctx = ssl.create_default_context()
    init_mail = imaplib.IMAP4_SSL(cfg["imap_server"], cfg["imap_port"], ssl_context=ctx)
    init_mail.login(cfg["username"], cfg["password"])
    init_mail.select("INBOX")
    status, data = init_mail.uid("search", None, "ALL")
    uids = data[0].split() if (status == "OK" and data[0]) else []
    last_uid = int(uids[-1]) if uids else 0
    init_mail.close()
    init_mail.logout()

    logging.info("Baseline initialized at IMAP UID #%d. Polling for messages...", last_uid)

    while True:
        try:
            ctx = ssl.create_default_context()
            mail = imaplib.IMAP4_SSL(cfg["imap_server"], cfg["imap_port"], ssl_context=ctx)
            mail.login(cfg["username"], cfg["password"])
            mail.select("INBOX")

            search_crit = f"UID {last_uid + 1}:*" if last_uid > 0 else "UNSEEN"
            status, data = mail.uid("search", None, search_crit)
            if status == "OK" and data[0]:
                uids = data[0].split()
                for uid_b in uids:
                    msg_uid = int(uid_b)
                    if msg_uid <= last_uid:
                        continue
                    last_uid = max(last_uid, msg_uid)

                    res, msg_data = mail.uid("fetch", uid_b, "(RFC822)")
                    if res != "OK":
                        continue

                    raw_email = msg_data[0][1]
                    parsed = email.message_from_bytes(raw_email)

                    from_header = str(parsed.get("From", ""))
                    _, sender_email = parseaddr(from_header)
                    sender_email = sender_email.lower().strip()
                    subject = str(parsed.get("Subject") or "(No Subject)").strip()
                    orig_msg_id = str(parsed.get("Message-ID") or "")

                    body = ""
                    if parsed.is_multipart():
                        for part in parsed.walk():
                            if part.get_content_type() == "text/plain":
                                body = part.get_payload(decode=True).decode(errors="replace")
                                break
                    else:
                        body = parsed.get_payload(decode=True).decode(errors="replace")

                    clean_body = clean_email_body(body)
                    if not clean_body:
                        clean_body = subject

                    to_headers = (
                        str(parsed.get("To", "")) + " " +
                        str(parsed.get("Delivered-To", "")) + " " +
                        str(parsed.get("X-Original-To", ""))
                    ).lower()

                    is_for_alexus = (
                        "alexus" in to_headers or
                        "alexus" in subject.lower() or
                        "alexus" in clean_body[:50].lower()
                    )
                    if not is_for_alexus:
                        continue

                    auth_senders = cfg.get("authorized_senders") or [cfg.get("authorized_sender", "")]
                    auth_senders = [s.lower().strip() for s in auth_senders if s]
                    uid_str = uid_b.decode("utf-8") if isinstance(uid_b, bytes) else str(uid_b)

                    if auth_senders and not any(a in sender_email for a in auth_senders):
                        logging.warning("Ignored message from unauthorized sender: %s", sender_email)
                        mail.uid("store", uid_str, "+FLAGS", "(\\Seen)")
                        continue

                    logging.info("Received email from [%s] subject: '%s'", sender_email, subject)

                    messages = [
                        {
                            "role": "system",
                            "content": (
                                f"{system_prompt}\n\n{boot_context}\n"
                                "[NOTE: You are replying via email thread. Keep response conversational, "
                                "helpful, punchy, and in character.]"
                            )
                        },
                        {"role": "user", "content": f"{subject}\n\n{clean_body}"}
                    ]

                    reply_text = "[Alexus Core Error]"
                    try:
                        url = f"{OLLAMA_HOST}/api/chat"
                        req_data = json.dumps({"model": "llama3.2:3b", "messages": messages, "stream": False}).encode("utf-8")
                        req = urllib.request.Request(url, data=req_data, headers={"Content-Type": "application/json"})
                        with urllib.request.urlopen(req, timeout=30) as r:
                            reply_res = json.loads(r.read().decode("utf-8"))
                            reply_text = reply_res.get("message", {}).get("content", "").strip()
                    except Exception as err:
                        logging.error("Inference request failed: %s", err)
                        reply_text = f"Error during local model inference: {err}"

                    try:
                        sent_from = send_reply_email(cfg, sender_email, subject, orig_msg_id, reply_text)
                        logging.info("Reply dispatched via SMTP to %s (From: %s)", sender_email, sent_from)
                    except Exception as err:
                        logging.error("SMTP delivery failed: %s", err)

                    mail.uid("store", uid_str, "+FLAGS", "(\\Seen)")

            mail.close()
            mail.logout()
            time.sleep(POLL_INTERVAL_SECONDS)

        except KeyboardInterrupt:
            logging.info("Mail daemon stopped by user.")
            break
        except Exception as err:
            logging.exception("Error in mail loop: %s", err)
            time.sleep(5)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "setup":
        cmd_mail_setup()
    elif len(sys.argv) > 1 and sys.argv[1] == "daemon":
        cmd_mail_daemon()
    else:
        print("Usage: mail_bridge.py [setup | daemon]")
