module main

import crypto.ed25519
import encoding.base64
import encoding.hex

// Reference vectors generated with the Python ed25519_orlp / auth.py this code replaces.
const ref_pub = '03A107BFF3CE10BE1D70DD18E74BC09967E4D6309BA50D5F1DDC8664125531B8'
const ref_prv = '3894eea49c580aef816935762be049559d6d1440dede12e6a125f1841fff8e6fa9d71862a3e5746b571be3d187b0041046f52ebd850c7cbd5fde8ee38473b649'

// ---- packets ----

fn test_connect_minimal() {
	p := mqtt_connect_packet(client_id: 't', keepalive: 30)
	assert p == [u8(0x10), 0x0d, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x1e, 0x00,
		0x01, 0x74]
}

fn test_connect_with_will_and_login() {
	p := mqtt_connect_packet(
		client_id: 'c'
		keepalive: 60
		has_login: true
		username: 'u'
		password: 'pw'
		will_topic: 'a/b'
		will_payload: 'off'
		will_retain: true
	)
	// flags: clean(2) + will(4) + will-retain(0x20) + user/pass(0xc0)
	assert p[0] == 0x10
	assert p[9] == u8(0x02 | 0x04 | 0x20 | 0xc0)
	assert p[10..12] == [u8(0), 60]
	tail := p[12..].bytestr()
	assert tail.contains('a/b') && tail.contains('off') && tail.contains('pw')
	assert int(p[1]) == p.len - 2
}

fn test_publish_and_retain_flag() {
	p := mqtt_publish_packet('t/x', 'hi', false)
	assert p == [u8(0x30), 7, 0, 3, 0x74, 0x2f, 0x78, 0x68, 0x69]
	assert mqtt_publish_packet('t/x', 'hi', true)[0] == 0x31
}

fn test_publish_long_payload_uses_multibyte_length() {
	p := mqtt_publish_packet('t', 'x'.repeat(300), false)
	// remaining length 303 = 0xAF 0x02
	assert p[1] == 0xaf && p[2] == 0x02
	mut buf := p.clone()
	pkt := mqtt_next_packet(mut buf)!
	assert pkt.ptype == 3 && pkt.body.len == 303 && buf.len == 0
}

fn test_next_packet_handles_partial_and_multiple() {
	mut buf := []u8{}
	buf << [u8(0x20)]
	assert mqtt_next_packet(mut buf)!.ptype == 0 // incomplete header
	buf << [u8(0x02), 0x00]
	assert mqtt_next_packet(mut buf)!.ptype == 0 // incomplete body
	buf << [u8(0x00), 0xd0, 0x00]
	a := mqtt_next_packet(mut buf)!
	assert a.ptype == mqtt_pt_connack && a.body == [u8(0), 0]
	b := mqtt_next_packet(mut buf)!
	assert b.ptype == mqtt_pt_pingresp && b.body.len == 0
	assert buf.len == 0
}

fn test_next_packet_rejects_bad_length() {
	mut buf := [u8(0x30), 0xff, 0xff, 0xff, 0xff, 0x01]
	if _ := mqtt_next_packet(mut buf) {
		assert false, 'expected error'
	}
	mut big := [u8(0x30), 0xff, 0xff, 0xff, 0x7f]
	if _ := mqtt_next_packet(mut big) {
		assert false, 'expected too-large error'
	}
}

fn test_connack_text() {
	assert mqtt_connack_text(4) == 'bad username or password'
	assert mqtt_connack_text(9) == 'return code 9'
}

// ---- websocket ----

fn test_ws_accept_matches_rfc_example() {
	assert ws_accept_for('dGhlIHNhbXBsZSBub25jZQ==') == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
}

fn test_ws_request_headers() {
	r := ws_request('mqtt.example.net', 443, '/', 'KEY', 'mqtt')
	assert r.starts_with('GET / HTTP/1.1\r\nHost: mqtt.example.net\r\n')
	assert r.contains('Sec-WebSocket-Protocol: mqtt\r\n')
	assert r.ends_with('\r\n\r\n')
	assert ws_request('h', 8084, '/mqtt', 'K', 'mqtt').contains('Host: h:8084\r\n')
}

fn test_ws_check_response() {
	key := 'dGhlIHNhbXBsZSBub25jZQ=='
	ok := 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n'
	ws_check_response(ok, key)!
	if _ := ws_check_response('HTTP/1.1 400 Bad Request\r\n', key) {
		assert false
	}
	if _ := ws_check_response('HTTP/1.1 101 x\r\nSec-WebSocket-Accept: nope\r\n', key) {
		assert false
	}
	if _ := ws_check_response('HTTP/1.1 101 x\r\nUpgrade: websocket\r\n', key) {
		assert false
	}
}

fn test_ws_frame_masks_payload() {
	f := ws_frame(ws_op_binary, [u8(1), 2, 3, 4, 5], [u8(0xaa), 0xbb, 0xcc, 0xdd])
	assert f == [u8(0x82), 0x85, 0xaa, 0xbb, 0xcc, 0xdd, 1 ^ 0xaa, 2 ^ 0xbb, 3 ^ 0xcc, 4 ^ 0xdd,
		5 ^ 0xaa]
}

fn test_ws_frame_length_encodings() {
	mask := [u8(0), 0, 0, 0]
	f126 := ws_frame(ws_op_binary, []u8{len: 200}, mask)
	assert f126[1] == 0x80 | 126 && f126[2] == 0 && f126[3] == 200
	f127 := ws_frame(ws_op_binary, []u8{len: 70000}, mask)
	assert f127[1] == 0x80 | 127 && f127[2..10] == [u8(0), 0, 0, 0, 0, 1, 0x11, 0x70]
}

fn test_ws_next_frame() {
	mut buf := [u8(0x82), 0x03, 1, 2] // partial
	assert !ws_next_frame(mut buf)!.complete
	buf << [u8(3), 0x89, 0x00] // rest + a ping
	f := ws_next_frame(mut buf)!
	assert f.complete && f.fin && f.opcode == ws_op_binary && f.payload == [u8(1), 2, 3]
	p := ws_next_frame(mut buf)!
	assert p.opcode == ws_op_ping && p.payload.len == 0 && buf.len == 0
	mut ext := [u8(0x82), 126, 0x01, 0x00]
	ext << []u8{len: 256, init: 7}
	e := ws_next_frame(mut ext)!
	assert e.complete && e.payload.len == 256
	mut fragged := [u8(0x02), 0x01, 9]
	g := ws_next_frame(mut fragged)!
	assert g.complete && !g.fin
}

fn test_ws_next_frame_rejects_masked_server_frame() {
	mut buf := [u8(0x82), 0x81, 0, 0, 0, 0, 1]
	if _ := ws_next_frame(mut buf) {
		assert false
	}
}

// ---- token / signature ----

fn test_sign_matches_reference_implementation() {
	pub_b := hex.decode(ref_pub)!
	prv_b := hex.decode(ref_prv)!
	cases := {
		'':              '9CA53579530654D5C3DF77089EF45EDA613E2FEDF670E96BEDAC4639504E5845EF4B95D5793077233DD16817B2532E9C5525872A73A4AD74B759369A9E05C102'
		'hello meshbbs': '40DD2CABF84FE05A8FB775D61085B94EA5DE6333246B6660A8B7B98B973BFDE566FDEF8EF2718C32F0AE4092719FAF06A9E6537C82C9587ACA7F8CE2F73C3600'
		'x'.repeat(300): '5772B3380D71D70A2EA21587786468294CDA03513A45BD18DCFD64B12F342EB58BF6E19FE5869523E89CFB095872B6B3826FE37AD846DCFB0C6379B780287C03'
	}
	for msg, want in cases {
		sig := mqtt_sign(msg.bytes(), pub_b, prv_b)!
		assert hex.encode(sig).to_upper() == want, 'signature mismatch for ${msg.len}-byte message'
		// and it is a standard Ed25519 signature
		assert ed25519.verify(pub_b, msg.bytes(), sig)!
	}
}

fn test_sign_rejects_bad_key_sizes() {
	if _ := mqtt_sign([u8(1)], []u8{len: 31}, []u8{len: 64}) {
		assert false
	}
	if _ := mqtt_sign([u8(1)], []u8{len: 32}, []u8{len: 32}) {
		assert false
	}
}

fn test_token_matches_reference_implementation() {
	tok := mqtt_create_token(ref_pub, ref_prv, 'mqtt.example.net', 3600, 1760000000, 'meshbbs-mqtt/1')!
	assert tok == 'eyJhbGciOiJFZDI1NTE5IiwidHlwIjoiSldUIn0.eyJwdWJsaWNLZXkiOiIwM0ExMDdCRkYzQ0UxMEJFMUQ3MEREMThFNzRCQzA5OTY3RTRENjMwOUJBNTBENUYxRERDODY2NDEyNTUzMUI4IiwiaWF0IjoxNzYwMDAwMDAwLCJleHAiOjE3NjAwMDM2MDAsImF1ZCI6Im1xdHQuZXhhbXBsZS5uZXQiLCJjbGllbnQiOiJtZXNoYmJzLW1xdHQvMSJ9.D858389F099063AA396B1BC02AC74610FE3A71BF02D617FEED2F93F51C8729455C738AEB1EE18B7151466BDA745F4A9AE962641454CA981FC0A8AE8B3377F70F'
}

fn test_token_client_claim_is_optional() {
	tok := mqtt_create_token(ref_pub, ref_prv, 'mqtt.example.net', 3600, 1760000000, '')!
	assert tok.ends_with('.F6A61C8F851806E5A2B3EC258C53A9E2DFD674472DDF55D7522D05A404AE22038268FE87A815D2658D85510D7DD1E7E41B7818CED7385496A5106B536D43ED05')
}

fn test_token_structure_has_no_padding() {
	tok := mqtt_create_token(ref_pub, ref_prv, 'a.example', 3600, 1760000000, 'c')!
	parts := tok.split('.')
	assert parts.len == 3
	assert !parts[0].contains('=') && !parts[1].contains('=')
	claims := base64.url_decode_str(parts[1])
	assert claims.contains('"aud":"a.example"') && claims.contains('"exp":1760003600')
	assert mqtt_username(ref_pub.to_lower()) == 'v1_${ref_pub}'
}

fn test_token_rejects_bad_keys() {
	if _ := mqtt_create_token('zz', ref_prv, 'a', 3600, 1, '') {
		assert false
	}
	if _ := mqtt_create_token(ref_pub[..62], ref_prv, 'a', 3600, 1, '') {
		assert false
	}
	if _ := mqtt_create_token(ref_pub, 'abcd', 'a', 3600, 1, '') {
		assert false
	}
}

fn test_json_str_escapes() {
	assert mqtt_json_str('a"b\\c') == '"a\\"b\\\\c"'
	assert mqtt_json_str('é') == '"\\u00e9"'
}
