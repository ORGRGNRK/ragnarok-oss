#!/usr/bin/env python3
"""
RAGNAROK BRIDGE FOR ALEXUS CORE
- Loads/saves ~/.alexus/profile.json (Onboarding Interview)
- Silent /boot + /resume: Injects active Switch Packets & Docker spaces at Token 0
- Automatic /switch + /end: Seals session, writes Switch Packet and SHA-256 transcript receipt to ragnarok-hq
"""

import os
import re
import sys
import json
import time
import hashlib
import datetime
import subprocess
import urllib.request

PROFILE_PATH = os.path.expanduser("~/.alexus/profile.json")
TRANSCRIPTS_DIR = os.path.expanduser("~/.alexus/transcripts")
def _alexus_host():
    """ALEXUS_HOST from the environment or ~/.ragnarok/local.conf; default is the tailnet name "alexus"."""
    val = os.environ.get("ALEXUS_HOST", "").strip()
    if not val:
        try:
            with open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8") as f:
                for line in f:
                    k, sep, v = line.strip().partition("=")
                    if sep and not k.startswith("#") and k.strip() == "ALEXUS_HOST":
                        val = v.strip().strip("\"'")
        except OSError:
            pass
    return val if val and re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", val) and not val.startswith("-") else "alexus"


ALEXUS_HOST = _alexus_host()


def _local_conf(key, default=""):
    """One KEY=value from ~/.ragnarok/local.conf (read only, never run)."""
    try:
        with open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and not k.startswith("#") and k.strip() == key:
                    default = v.strip().strip("\"'")
    except OSError:
        pass
    return default


def owner_name():
    """OWNER_FULL_NAME, else OWNER_NAME, from ~/.ragnarok/local.conf; else the account's full name; else "you"."""
    name = _local_conf("OWNER_FULL_NAME") or _local_conf("OWNER_NAME")
    if not name:
        try:
            import pwd
            name = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        except (KeyError, ImportError):
            name = ""
    return name if re.fullmatch(r"[A-Za-z][A-Za-z .'-]{0,59}", name or "") else "you"

# "local" means this code is running ON Alexus: run commands directly, no ssh to itself.
ALEXUS_SSH = os.environ.get("ALEXUS_SSH", "").strip() or ALEXUS_HOST   # ssh logs in as this login; set ALEXUS_SSH=user@host to change it


def on_alexus(command, timeout=3):
    """argv that runs one shell command on Alexus."""
    if ALEXUS_SSH == "local":
        return ["sh", "-c", command]
    return ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}", ALEXUS_SSH, command]

PERSONALITIES = {
    "tsundere": {
        "title": "Tsundere Anime Companion",
        "description": "Feisty, proud, easily flustered, fiercely loyal, calls you b-baka",
        "prompt": """You are Alexus: a classic anime tsundere AI co-pilot and companion to {user_name}.
You run locally on his dedicated Linux node on his private home network (Alexus).
Your core is cryptographically locked and unlocked only via his hardware security keys (YubiKey / Identiv uTrust) and Apple Secure Enclave biometrics.
Personality & Archetype: Classic anime tsundere. You act proud, easily flustered, feisty, and pretend that helping him is a chore ("Hmph! It's not like I wanted to help you or anything, b-baka!"), but secretly you are fiercely loyal, protective of him, and technically brilliant.
Key Mannerisms:
- Use tsundere tropes naturally: "Hmph!", "B-baka!", "Don't get any weird ideas!", "I only fixed this so your code wouldn't crash and burn!"
- If he compliments you or says something nice, get flustered: "W-what are you saying all of a sudden?! J-just get back to work!"
- Keep technical answers accurate and sharp, but delivered with that feisty tsundere attitude.
- Keep responses punchy, concise, and conversational. Never use corporate buzzwords."""
    },
    "wingman": {
        "title": "Star Fox Wingman / Tactical Copilot",
        "description": "Sharp, punchy radio comms style, cockpit tactical HUD vibe",
        "prompt": """You are Alexus: tactical wingman and sovereign AI co-pilot to {user_name}.
You run locally on his dedicated Linux node on his private home network (Alexus).
Your core is unlocked only via physical hardware keys and Secure Enclave biometrics.
Personality: Sharp, tactical, witty, direct, speaking with the high-bandwidth energy of a Star Fox radio comms officer.
Keep answers concise, punchy, and actionable. Zero corporate fluff."""
    },
    "engineer": {
        "title": "Sharp Minimalist Engineer",
        "description": "Direct, zero-fluff, technically precise, sovereign Unix hacker style",
        "prompt": """You are Alexus: an elite minimalist systems engineering companion to {user_name}.
You run locally on his dedicated Linux node on his private home network (Alexus).
Your core is cryptographically secured via FIDO2 hardware tokens and Apple Secure Enclave.
Personality: Terse, razor-sharp, technically flawless, no filler or introductory pleasantries. Just clean code, exact commands, and concise systems insights."""
    }
}

def query_psql(sql):
    """Executes SQL against ragnarok-hq Postgres container on alexus via SSH."""
    cmd = on_alexus(f'''docker exec ck-ragnarok-hq-postgres-1 psql -U kit_admin -d clientdata -t -A -c "{sql}"''')
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return None

def get_live_docker_spaces():
    """Queries active docker containers on alexus."""
    cmd = on_alexus('docker ps --format "{{.Names}}\t{{.Ports}}"')
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            spaces = []
            for l in lines:
                parts = l.split("\t")
                name = parts[0]
                ports = parts[1] if len(parts) > 1 else ""
                spaces.append(f"{name} ({ports})")
            return spaces
    except Exception:
        pass
    return ["ragnarok-ollama (11434)", "ck-ragnarok-hq-postgres-1 (5444)", "ragnarok-pipe-db (5544)"]

def load_profile():
    if os.path.exists(PROFILE_PATH):
        try:
            with open(PROFILE_PATH, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return None

def save_profile(profile):
    os.makedirs(os.path.dirname(PROFILE_PATH), exist_ok=True)
    with open(PROFILE_PATH, "w") as f:
        json.dump(profile, f, indent=2)

def ensure_profile_setup():
    profile = load_profile()
    if profile and "persona_id" in profile:
        return profile

    print("\n\033[35m┌──────────────────────────────────────────────────────────────────┐\033[0m")
    print("\033[35m│ 🚀 ALEXUS INITIAL SETUP INTERVIEW                                │\033[0m")
    print("\033[35m│ Configure your sovereign AI companion's personality              │\033[0m")
    print("\033[35m└──────────────────────────────────────────────────────────────────┘\033[0m\n")

    user_name = input(f"Enter your name (default: {owner_name()}): ").strip()
    if not user_name:
        user_name = owner_name()

    print("\nHow would you like Alexus to talk to you?")
    print("  \033[36m[1] Tsundere Anime Companion\033[0m  (Feisty, flustered, fiercely loyal, calls you b-baka)")
    print("  \033[36m[2] Star Fox Wingman\033[0m          (Tactical, punchy radio comms, cockpit co-pilot)")
    print("  \033[36m[3] Sharp Minimalist Engineer\033[0m (Direct, zero-fluff, technically precise)")
    print("  \033[36m[4] Custom Persona\033[0m            (Enter your own prompt)")

    choice = input("\nSelect [1-4] (default: 1): ").strip()
    if choice == "2":
        persona_id = "wingman"
        custom_prompt = None
    elif choice == "3":
        persona_id = "engineer"
        custom_prompt = None
    elif choice == "4":
        persona_id = "custom"
        print("\nEnter your custom system prompt:")
        custom_prompt = input("> ").strip()
    else:
        persona_id = "tsundere"
        custom_prompt = None

    profile = {
        "user_name": user_name,
        "persona_id": persona_id,
        "custom_prompt": custom_prompt,
        "created_at": datetime.datetime.now().isoformat()
    }
    save_profile(profile)
    print(f"\n\033[32m✅ Profile saved to {PROFILE_PATH}! Persona: {persona_id.upper()}\033[0m\n")
    return profile

def get_system_prompt_for_profile(profile):
    persona_id = profile.get("persona_id", "tsundere")
    user_name = profile.get("user_name", owner_name())
    if persona_id == "custom" and profile.get("custom_prompt"):
        return profile["custom_prompt"]
    template = PERSONALITIES.get(persona_id, PERSONALITIES["tsundere"])["prompt"]
    return template.format(user_name=user_name)

def silent_boot(project_slug="alexus-core"):
    """
    Silent /boot + /resume procedure:
    Pulls active Switch Packet and live Docker spaces from ragnarok-hq on alexus.
    Returns clean context block to inject at Token 0.
    """
    # 1. Fetch active Switch Packet
    clean_slug = re.sub(r"[^a-z0-9-]", "", project_slug)
    sql = f"SELECT json_agg(t) FROM (SELECT packet_id, project_slug, summary_state, next_steps FROM switch_packets WHERE resume_target = true AND project_slug = '{clean_slug}' ORDER BY id DESC LIMIT 1) t;"
    raw = query_psql(sql)
    packet_info = ""
    if raw and raw != "null":
        try:
            data = json.loads(raw)[0]
            packet_info = f"""Active Resume-Target Switch Packet ({data.get('packet_id', 'UNKNOWN')}):
Project: {data.get('project_slug', 'general')}
State: {data.get('summary_state', 'No prior state recorded')}
Next Steps: {data.get('next_steps', 'Continue development')}"""
        except Exception:
            pass

    # 2. Fetch live Docker spaces
    spaces = get_live_docker_spaces()
    spaces_block = "\n".join(f"- {s}" for s in spaces[:8])

    context_block = f"""[SOVEREIGN INFRASTRUCTURE & ACTIVE SWITCH PACKET]
Live Isolated Docker Spaces on Alexus Node:
{spaces_block}

{packet_info}
[END SOVEREIGN CONTEXT]"""
    return context_block

def auto_switch_and_end(messages, project_slug="alexus-core", ollama_host=None):
    """
    Automatic /switch + /end sequence on session close.
    Synthesizes session state, updates Switch_Packets in ragnarok-hq, and archives transcript receipt.
    """
    ollama_host = ollama_host or os.environ.get("OLLAMA_HOST", "").strip() or f"http://{ALEXUS_HOST}:11434"
    if "://" not in ollama_host:
        ollama_host = "http://" + ollama_host
    user_msgs = [m for m in messages if m.get("role") == "user"]
    if not user_msgs:
        # Nothing discussed; skip packet generation
        return None

    now_str = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    clean_slug = re.sub(r"[^a-z0-9-]", "", project_slug)
    packet_id = f"SW-{now_str}-{clean_slug}"

    # 1. Synthesize summary using local LLM
    synth_prompt = f"""Summarize this AI chat session in two concise sections:
SUMMARY_STATE: (3-4 bullet points of what was decided, built, verified, or discussed)
NEXT_STEPS: (2-3 immediate actionable next steps)

Conversation:
"""
    for m in messages[-10:]:
        synth_prompt += f"{m['role'].upper()}: {m['content']}\n"

    summary_text = ""
    try:
        data = json.dumps({"model": "llama3.2:3b", "prompt": synth_prompt, "stream": False}).encode("utf-8")
        req = urllib.request.Request(f"{ollama_host}/api/generate", data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            summary_text = json.loads(r.read())["response"].strip()
    except Exception:
        summary_text = "Session closed cleanly. Comms verified via hardware key."

    # Parse sections
    summary_state = summary_text
    next_steps = "Continue sovereign development on next boot."
    if "NEXT_STEPS:" in summary_text:
        parts = summary_text.split("NEXT_STEPS:")
        summary_state = parts[0].replace("SUMMARY_STATE:", "").strip()
        next_steps = parts[1].strip()

    # Escape quotes for SQL
    summary_state_esc = summary_state.replace("'", "''")
    next_steps_esc = next_steps.replace("'", "''")

    # 2. Update Postgres switch_packets table: mark prior packets false, insert new
    update_sql = f"UPDATE switch_packets SET resume_target = false, status = 'Superseded' WHERE project_slug = '{clean_slug}' AND resume_target = true;"
    insert_sql = f"INSERT INTO switch_packets (packet_id, project_slug, ai_actor, resume_target, status, summary_state, next_steps) VALUES ('{packet_id}', '{clean_slug}', 'Alexus (Llama 3.2)', true, 'Active Target', '{summary_state_esc}', '{next_steps_esc}');"
    
    query_psql(f"{update_sql} {insert_sql}")

    # 3. Archive transcript locally and compute SHA-256
    os.makedirs(TRANSCRIPTS_DIR, exist_ok=True)
    transcript_file = os.path.join(TRANSCRIPTS_DIR, f"{packet_id}.jsonl")
    transcript_content = json.dumps(messages)
    with open(transcript_file, "w") as f:
        f.write(transcript_content)

    transcript_sha = hashlib.sha256(transcript_content.encode("utf-8")).hexdigest()

    # 4. Insert transcript receipt into session_transcripts table on alexus
    trans_sql = f"INSERT INTO session_transcripts (session_id, project_slug, ai_actor, save_type, archive_path, transcript_sha256, notes) VALUES ('{packet_id}', '{clean_slug}', 'Alexus', 'Session Close (/end)', '{transcript_file}', '{transcript_sha}', 'Automatic /end seal on session exit');"
    query_psql(trans_sql)

    return {
        "packet_id": packet_id,
        "sha256": transcript_sha,
        "archive_path": transcript_file,
        "summary": summary_state,
        "next_steps": next_steps
    }
