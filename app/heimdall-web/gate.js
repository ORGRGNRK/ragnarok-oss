// YubiKey gate for Heimdall Web (WebAuthn). touch(purpose) asks for a security-key touch and returns the signed
// proof the server checks; register() adds a key while registration is open on the server.
const b64u = buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), c => c.charCodeAt(0));

async function gateChallenge(purpose) {
  if (!window.isSecureContext || !navigator.credentials) {
    throw new Error("YubiKey needs the HTTPS address: https://__HEIMDALL_WEB_HOST__" + (location.pathname || "/"));
  }
  const r = await fetch("api/gate/challenge", { method: "POST", body: JSON.stringify({ purpose }) });
  const d = await r.json();
  if (!r.ok) throw new Error(d.error);
  return d;
}

async function touch(purpose) {
  const c = await gateChallenge(purpose);
  if (!c.keys.length) throw new Error("No YubiKey registered yet");
  const cred = await navigator.credentials.get({ publicKey: {
    challenge: unb64u(c.challenge), rpId: c.rpId, timeout: 60000, userVerification: "discouraged",
    allowCredentials: c.keys.map(id => ({ type: "public-key", id: unb64u(id) })) } });
  return { id: b64u(cred.rawId), clientDataJSON: b64u(cred.response.clientDataJSON),
           authenticatorData: b64u(cred.response.authenticatorData), signature: b64u(cred.response.signature) };
}

async function register(name) {
  const c = await gateChallenge("register");
  const cred = await navigator.credentials.create({ publicKey: {
    challenge: unb64u(c.challenge), rp: { id: c.rpId, name: "Heimdall" },
    user: { id: crypto.getRandomValues(new Uint8Array(16)), name: "owner", displayName: "Owner" },
    pubKeyCredParams: [{ type: "public-key", alg: -7 }], timeout: 90000, attestation: "none",
    authenticatorSelection: { authenticatorAttachment: "cross-platform", userVerification: "discouraged", residentKey: "discouraged" },
    excludeCredentials: c.keys.map(id => ({ type: "public-key", id: unb64u(id) })) } });
  const r = await fetch("api/gate/register", { method: "POST", body: JSON.stringify({
    name, clientDataJSON: b64u(cred.response.clientDataJSON), attestationObject: b64u(cred.response.attestationObject) }) });
  const d = await r.json();
  if (!r.ok) throw new Error(d.error);
  return d.keys;
}
