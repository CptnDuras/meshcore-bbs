module main

import crypto.ed25519.internal.edwards25519
import crypto.sha512
import encoding.base64
import encoding.hex

// MeshCore MQTT auth tokens: JWT-style, Ed25519-signed with the node's key.
//
//   header  {"alg":"Ed25519","typ":"JWT"}
//   claims  {"publicKey":<UPPER HEX>,"iat":..,"exp":..,"aud":<broker>[,"client":..]}
//   token   b64url(header).b64url(claims).<UPPER HEX signature>
//   login   username "v1_<UPPER HEX pubkey>", password = token
//
// The key is MeshCore's 64-byte *expanded* private key (orlp ed25519: clamped
// scalar || hash prefix), not a seed, so V's seed-based crypto.ed25519.sign
// cannot be used directly. This is that algorithm with the expansion step
// already done. It depends on the stdlib's edwards25519 internals; the tests
// pin its output against the reference implementation.

pub fn mqtt_username(public_key_hex string) string {
	return 'v1_' + public_key_hex.to_upper()
}

// mqtt_sign signs message with an expanded private key (64 bytes) and its
// public key (32 bytes), producing a standard 64-byte Ed25519 signature.
pub fn mqtt_sign(message []u8, public_key []u8, expanded_private []u8) ![]u8 {
	if public_key.len != 32 {
		return error('public key must be 32 bytes, got ${public_key.len}')
	}
	if expanded_private.len != 64 {
		return error('private key must be 64 bytes, got ${expanded_private.len}')
	}
	mut s := edwards25519.new_scalar()
	s.set_bytes_with_clamping(expanded_private[..32])!
	prefix := expanded_private[32..]

	mut mh := sha512.new()
	mh.write(prefix)!
	mh.write(message)!
	msg_digest := mh.sum([]u8{cap: sha512.size})
	mut r := edwards25519.new_scalar()
	r.set_uniform_bytes(msg_digest)!
	mut rr := edwards25519.Point{}
	rr.scalar_base_mult(mut r)

	mut kh := sha512.new()
	kh.write(rr.bytes())!
	kh.write(public_key)!
	kh.write(message)!
	hram := kh.sum([]u8{cap: sha512.size})
	mut k := edwards25519.new_scalar()
	k.set_uniform_bytes(hram)!
	mut ss := edwards25519.new_scalar()
	ss.multiply_add(k, s, r)

	mut sig := rr.bytes()
	sig << ss.bytes()
	return sig
}

fn mqtt_b64url(data []u8) string {
	return base64.url_encode(data).trim_right('=')
}

// mqtt_json_str quotes s as a JSON string (ASCII-safe like Python's json.dumps).
fn mqtt_json_str(s string) string {
	mut b := []u8{cap: s.len + 2}
	b << `"`
	for r in s.runes() {
		match true {
			r == `"` { b << '\\"'.bytes() }
			r == `\\` { b << '\\\\'.bytes() }
			r == `\n` { b << '\\n'.bytes() }
			r == `\r` { b << '\\r'.bytes() }
			r == `\t` { b << '\\t'.bytes() }
			r < 0x20 || r > 0x7e { b << '\\u${u32(r):04x}'.bytes() }
			else { b << u8(r) }
		}
	}
	b << `"`
	return b.bytestr()
}

// mqtt_create_token builds the signed login token. now is unix seconds.
pub fn mqtt_create_token(public_key_hex string, private_key_hex string, audience string, ttl i64, now i64, client string) !string {
	pub_b := hex.decode(public_key_hex) or { return error('key is not valid hex: ${err}') }
	prv_b := hex.decode(private_key_hex) or { return error('key is not valid hex: ${err}') }
	if pub_b.len != 32 {
		return error('public key must be 32 bytes, got ${pub_b.len}')
	}
	if prv_b.len != 64 {
		return error('private key must be 64 bytes, got ${prv_b.len}')
	}
	mut claims := '{"publicKey":${mqtt_json_str(public_key_hex.to_upper())},"iat":${now},"exp":${now + ttl},"aud":${mqtt_json_str(audience)}'
	if client.len > 0 {
		claims += ',"client":${mqtt_json_str(client)}'
	}
	claims += '}'
	head := mqtt_b64url('{"alg":"Ed25519","typ":"JWT"}'.bytes())
	body := mqtt_b64url(claims.bytes())
	signing_input := '${head}.${body}'
	sig := mqtt_sign(signing_input.bytes(), pub_b, prv_b)!
	return '${signing_input}.${hex.encode(sig).to_upper()}'
}
