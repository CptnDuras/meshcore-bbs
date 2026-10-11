"""MeshCore MQTT auth tokens: JWT-style, Ed25519-signed with the node's key.

Format (as accepted by the public MeshCore MQTT brokers):
  header  {"alg":"Ed25519","typ":"JWT"}
  claims  {"publicKey":<UPPER HEX>,"iat":..,"exp":..,"aud":<broker>}
  token   b64url(header).b64url(claims).<UPPER HEX signature>
  login   username "v1_<UPPER HEX pubkey>", password = token

The key is MeshCore's 64-byte expanded private key (orlp ed25519), so the
signing must use ed25519_orlp, not a seed-based library.
"""
import base64
import json
import time

from ed25519_orlp import ed25519_sign


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def username(public_key_hex: str) -> str:
    return "v1_" + public_key_hex.upper()


def create_token(public_key_hex: str, private_key_hex: str, audience: str,
                 ttl: int = 3600, now: int | None = None, client: str = "") -> str:
    try:
        pub = bytes.fromhex(public_key_hex)
        prv = bytes.fromhex(private_key_hex)
    except ValueError as e:
        raise ValueError(f"key is not valid hex: {e}") from None
    if len(pub) != 32:
        raise ValueError(f"public key must be 32 bytes, got {len(pub)}")
    if len(prv) != 64:
        raise ValueError(f"private key must be 64 bytes, got {len(prv)}")
    iat = int(time.time()) if now is None else int(now)
    claims = {"publicKey": public_key_hex.upper(), "iat": iat, "exp": iat + ttl, "aud": audience}
    if client:
        claims["client"] = client
    head = _b64url(json.dumps({"alg": "Ed25519", "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64url(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{head}.{body}"
    sig = ed25519_sign(signing_input.encode(), pub, prv)
    return f"{signing_input}.{sig.hex().upper()}"
