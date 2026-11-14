"""A software security key for the tests: it does what a YubiKey does for WebAuthn (register, sign a touch),
so the server's real checks run without a person. Needs the `cryptography` package (Alexus has it)."""
import hashlib, json, os, struct

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

RP_ID, ORIGIN = "heimdall.example.ts.net", "https://heimdall.example.ts.net"


def b64u(b):
    import base64
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def enc(v):
    """Tiny CBOR writer for the test authenticator."""
    def head(major, n):
        if n < 24:
            return bytes([major << 5 | n])
        for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
            if n < 1 << (8 * size):
                return bytes([major << 5 | info]) + n.to_bytes(size, "big")
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, bytes):
        return head(2, len(v)) + v
    if isinstance(v, str):
        return head(3, len(v.encode())) + v.encode()
    if isinstance(v, dict):
        return head(5, len(v)) + b"".join(enc(k) + enc(x) for k, x in v.items())
    raise TypeError(v)


class FakeKey:
    def __init__(self, rp=RP_ID):
        self.priv = ec.generate_private_key(ec.SECP256R1())
        self.cred_id = os.urandom(32)
        self.count = 0
        self.rp = rp

    def client_data(self, kind, challenge, origin=ORIGIN):
        return json.dumps({"type": kind, "challenge": challenge, "origin": origin}).encode()

    def register(self, challenge, origin=ORIGIN):
        n = self.priv.public_key().public_numbers()
        cose = enc({1: 2, 3: -7, -1: 1, -2: n.x.to_bytes(32, "big"), -3: n.y.to_bytes(32, "big")})
        ad = hashlib.sha256(self.rp.encode()).digest() + bytes([0x41]) + struct.pack(">I", self.count) \
            + b"\0" * 16 + struct.pack(">H", len(self.cred_id)) + self.cred_id + cose
        return {"clientDataJSON": b64u(self.client_data("webauthn.create", challenge, origin)),
                "attestationObject": b64u(enc({"fmt": "none", "attStmt": {}, "authData": ad}))}

    def touch(self, challenge, origin=ORIGIN, touched=True, bump=1, kind="webauthn.get"):
        self.count += bump
        ad = hashlib.sha256(self.rp.encode()).digest() + bytes([0x01 if touched else 0x00]) + struct.pack(">I", self.count)
        cdj = self.client_data(kind, challenge, origin)
        sig = self.priv.sign(ad + hashlib.sha256(cdj).digest(), ec.ECDSA(hashes.SHA256()))
        return {"id": b64u(self.cred_id), "clientDataJSON": b64u(cdj), "authenticatorData": b64u(ad), "signature": b64u(sig)}
