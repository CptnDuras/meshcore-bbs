import base64
import json
import time

import auth
import ed25519_orlp as ed


def _keys():
    pub, prv, _seed = ed.ed25519_create_keypair(bytes(range(32)))
    return pub.hex().upper(), prv.hex()


def _b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def test_token_structure_and_claims():
    pub, prv = _keys()
    tok = auth.create_token(pub, prv, audience="mqtt.example.org", ttl=3600, now=1_760_000_000)
    head, body, sig = tok.split(".")
    assert json.loads(_b64d(head)) == {"alg": "Ed25519", "typ": "JWT"}
    claims = json.loads(_b64d(body))
    assert claims["publicKey"] == pub
    assert claims["iat"] == 1_760_000_000
    assert claims["exp"] == 1_760_000_000 + 3600
    assert claims["aud"] == "mqtt.example.org"
    # upper-case hex signature, 64 bytes
    assert sig == sig.upper() and len(sig) == 128


def test_token_signature_verifies():
    pub, prv = _keys()
    tok = auth.create_token(pub, prv, audience="a", now=1)
    head, body, sig = tok.split(".")
    ok = ed.ed25519_verify(bytes.fromhex(sig), f"{head}.{body}".encode(), bytes.fromhex(pub))
    assert ok


def test_token_is_compact_json_without_padding():
    pub, prv = _keys()
    tok = auth.create_token(pub, prv, audience="a", now=1)
    head, body, _ = tok.split(".")
    assert "=" not in head and "=" not in body
    assert b" " not in _b64d(body)  # separators=(',', ':')


def test_username():
    assert auth.username("ab" * 32) == "v1_" + "AB" * 32


def test_rejects_bad_keys():
    pub, prv = _keys()
    for bad_pub, bad_prv in [("00", prv), (pub, "00"), ("zz" * 32, prv)]:
        try:
            auth.create_token(bad_pub, bad_prv, audience="a")
        except ValueError:
            continue
        raise AssertionError("bad key accepted")


def test_default_now_is_current_time():
    pub, prv = _keys()
    t0 = int(time.time())
    claims = json.loads(_b64d(auth.create_token(pub, prv, audience="a").split(".")[1]))
    assert t0 <= claims["iat"] <= t0 + 2


def test_client_claim_optional():
    pub, prv = _keys()
    c = json.loads(_b64d(auth.create_token(pub, prv, audience="a", client="meshbbs-mqtt/1").split(".")[1]))
    assert c["client"] == "meshbbs-mqtt/1"
    c = json.loads(_b64d(auth.create_token(pub, prv, audience="a").split(".")[1]))
    assert "client" not in c
