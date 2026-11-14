# local-config.sh — sourced by bin scripts. Reads ~/.ragnarok/local.conf (KEY=value, not in git).
# The file is only read line by line, never sourced or run. Missing file/key or an odd value = the generic default.
# Same keys and rules as Sources/Heimdall/LocalConfig.swift. Sets:
#   ALEXUS_HOST ALEXUS_USER ALEXUS_TAILSCALE ALEXUS_SSH OLLAMA_URL OWNER_NAME
# RAGNAROK_LOCAL_CONF overrides the path (used by tests).

lc_get() { # KEY -> value from the file, or nothing
  local f="${RAGNAROK_LOCAL_CONF:-$HOME/.ragnarok/local.conf}" line k v out=""
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    k="${line%%=*}"; k="${k%"${k##*[![:space:]]}"}"
    [ "$k" = "$1" ] || continue
    v="${line#*=}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in \"*\"|\'*\') [ ${#v} -ge 2 ] && v="${v:1:${#v}-2}" ;; esac
    out=$v   # last one wins, like the Swift reader
  done < "$f"
  printf '%s' "$out"
}
lc_host_ok() { [ -n "$1" ] && [ ${#1} -le 253 ] && [[ "$1" != -* ]] && [[ "$1" =~ ^[A-Za-z0-9.:-]+$ ]]; }
lc_user_ok() { [ ${#1} -le 32 ] && [[ "$1" =~ ^[a-z_][A-Za-z0-9_.-]*$ ]]; }
lc_url_ok()  { [[ "$1" =~ ^https?://([A-Za-z0-9.:-]+|\[[0-9A-Fa-f:.]+\])(/[A-Za-z0-9._~/-]*)?$ ]] && [[ "${1#*://}" != -* ]]; }

_v=$(lc_get ALEXUS_HOST);      lc_host_ok "$_v" && ALEXUS_HOST=$_v      || ALEXUS_HOST=alexus.local
_lu=$(id -un 2>/dev/null); lc_user_ok "$_lu" || _lu=user
_v=$(lc_get ALEXUS_USER);      lc_user_ok "$_v" && ALEXUS_USER=$_v      || ALEXUS_USER=$_lu
_v=$(lc_get ALEXUS_TAILSCALE); lc_host_ok "$_v" && ALEXUS_TAILSCALE=$_v || ALEXUS_TAILSCALE=alexus
_v=$(lc_get OLLAMA_URL); while [[ "$_v" == */ ]]; do _v="${_v%/}"; done
lc_url_ok "$_v" && OLLAMA_URL=$_v || OLLAMA_URL="http://$ALEXUS_HOST:11434"
ALEXUS_SSH="$ALEXUS_USER@$ALEXUS_HOST"
_name_re="^[A-Za-z][A-Za-z .'-]{0,39}\$"
_v=$(lc_get OWNER_NAME)
if [[ ! "$_v" =~ $_name_re ]]; then
  _v=$( (id -F 2>/dev/null || getent passwd "$_lu" 2>/dev/null | cut -d: -f5 | cut -d, -f1) | awk '{print $1}')
  [[ "$_v" =~ $_name_re ]] || _v=you
fi
OWNER_NAME=$_v
unset _v _lu _name_re
