module main

import json2

// --- over-the-air packet header parsing ---
// Expected hashes below were computed independently with Python hashlib:
//   sha256(payload_type [+ path_len if TRACE] + payload)[:8], upper-case hex.

fn test_parse_packet_flood_txt() {
	// header 0x09 = route FLOOD(1), type TXT_MSG(2); path_len 2; path AA BB; payload 5 bytes
	raw := [u8(0x09), 0x02, 0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0x05]
	p := parse_packet(raw) or { panic('should parse') }
	assert p.route == 'F'
	assert p.packet_type == 2
	assert p.payload_len == 5
	assert p.raw_len == 9
	assert p.hash == '23ADB40BCDA9A241'
}

fn test_parse_packet_transport_direct_advert() {
	// header (4<<2)|3 = 0x13: TRANSPORT_DIRECT, ADVERT. 4 transport bytes, path_len 0, payload 4 bytes
	raw := [u8(0x13), 0x11, 0x22, 0x33, 0x44, 0x00, 0xA1, 0xA2, 0xA3, 0xA4]
	p := parse_packet(raw) or { panic('should parse') }
	assert p.route == 'D'
	assert p.packet_type == 4
	assert p.payload_len == 4
	assert p.hash == '5E9E8528BABB5B5C'
}

fn test_parse_packet_trace_hash_includes_path_len() {
	// header (9<<2)|1 = 0x25 TRACE flood, path_len 3, path 3 bytes, payload 0A 0B 0C
	raw := [u8(0x25), 0x03, 0x01, 0x02, 0x03, 0x0A, 0x0B, 0x0C]
	p := parse_packet(raw) or { panic('should parse') }
	assert p.packet_type == 9
	assert p.hash == '76647EB19800AAE8'
}

fn test_parse_packet_two_byte_path_hashes() {
	// path_len 0x42: hash size 2 (bits 6-7 = 1), 2 hops -> 4 path bytes
	raw := [u8(0x09), 0x42, 0xA1, 0xA2, 0xB1, 0xB2, 0x01, 0x02, 0x03, 0x04, 0x05]
	p := parse_packet(raw) or { panic('should parse') }
	assert p.payload_len == 5
	assert p.hash == '23ADB40BCDA9A241'
}

fn test_parse_packet_rejects_garbage() {
	if _ := parse_packet([]u8{}) {
		panic('empty must fail')
	}
	// path_len claims more bytes than exist
	if _ := parse_packet([u8(0x09), 0x3F, 0x01]) {
		panic('truncated path must fail')
	}
	// reserved hash size (bits 6-7 = 3 -> size 4)
	if _ := parse_packet([u8(0x09), 0xC1, 0x01, 0x02, 0x03]) {
		panic('reserved hash size must fail')
	}
	// no payload at all
	if _ := parse_packet([u8(0x09), 0x00]) {
		panic('payload-less packet must fail')
	}
}

// --- topics ---

fn test_observer_topic() {
	assert observer_topic('BYG', 'ab12', 'packets') == 'meshcore/BYG/AB12/packets'
	assert observer_topic('byg', 'AB12', 'status') == 'meshcore/BYG/AB12/status'
}

// --- validation ---

fn test_valid_iata() {
	assert valid_iata('BYG')
	assert valid_iata('shr')
	assert !valid_iata('')
	assert !valid_iata('BY')
	assert !valid_iata('BYGG')
	assert !valid_iata('B1G')
}

fn test_validate_broker() {
	ok := MqttBroker{
		name:      'x'
		host:      'mqtt.example.org'
		port:      443
		transport: 'wss'
		auth:      'token'
		audience:  'mqtt.example.org'
	}
	assert mqtt_validate_broker(ok) == ''
	mut b := ok
	b.host = ''
	assert mqtt_validate_broker(b).contains('host')
	b = ok
	b.port = 0
	assert mqtt_validate_broker(b).contains('port')
	b = ok
	b.port = 70000
	assert mqtt_validate_broker(b).contains('port')
	b = ok
	b.transport = 'carrier-pigeon'
	assert mqtt_validate_broker(b).contains('transport')
	b = ok
	b.auth = 'token'
	b.transport = 'tcp'
	// token auth needs TLS-capable transport? no: allowed, just must have audience
	b.audience = ''
	assert mqtt_validate_broker(b).contains('audience')
	b = ok
	b.name = ''
	assert mqtt_validate_broker(b).contains('name')
	b = ok
	b.host = 'bad host;rm -rf'
	assert mqtt_validate_broker(b).contains('host')
	b = ok
	b.auth = 'password'
	b.username = ''
	assert mqtt_validate_broker(b).contains('username')
}

fn test_presets_are_valid_and_known() {
	names := mqtt_preset_names()
	for want in ['meshmapper', 'waev-a', 'waev-b', 'letsmesh-us', 'letsmesh-eu', 'local'] {
		assert want in names
	}
	for n in names {
		b := mqtt_preset(n) or { panic('preset ${n} missing') }
		assert mqtt_validate_broker(b) == '', 'preset ${n} invalid: ${mqtt_validate_broker(b)}'
	}
	mm := mqtt_preset('meshmapper') or { panic('x') }
	assert mm.host == 'mqtt.meshmapper.net'
	assert mm.port == 443
	assert mm.transport == 'wss'
	assert mm.auth == 'token'
	assert mm.audience == 'mqtt.meshmapper.net'
	if _ := mqtt_preset('nope') {
		panic('unknown preset must be none')
	}
}

// --- payload JSON (matches the field set map services already consume) ---

fn test_observer_packet_json() {
	raw := [u8(0x09), 0x02, 0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0x05]
	s := observer_packet_json('MESHBBS', 'ABCD', 1760000000, 5.5, -97.0, raw) or { panic('observer_packet_json returned none') }
	m := json2.decode[map[string]string](s) or { panic('payload must be a flat string map: ${err}') }
	assert m['origin'] == 'MESHBBS'
	assert m['origin_id'] == 'ABCD'
	assert m['type'] == 'PACKET'
	assert m['direction'] == 'rx'
	assert m['len'] == '9'
	assert m['packet_type'] == '2'
	assert m['route'] == 'F'
	assert m['payload_len'] == '5'
	assert m['raw'] == '09 02 AA BB 01 02 03 04 05'.replace(' ', '')
	assert m['SNR'] == '5'
	assert m['RSSI'] == '-97'
	assert m['hash'] == '23ADB40BCDA9A241'
	// 1760000000 = 2025-10-09 08:53:20 UTC
	assert m['time'] == '08:53:20'
	assert m['date'] == '9/10/2025'
	assert m['timestamp'].starts_with('2025-10-09T08:53:20')
}

fn test_observer_packet_json_rejects_unparseable() {
	if _ := observer_packet_json('N', 'K', 0, 0, 0, [u8(1)]) {
		panic('garbage packet must not be published')
	}
}

fn test_observer_status_json() {
	s := observer_status_json('online', 'MESHBBS', 'ABCD', 1760000000, 'Heltec V3', '1.17.1')
	m := json2.decode[map[string]string](s) or { panic(err) }
	assert m['status'] == 'online'
	assert m['origin'] == 'MESHBBS'
	assert m['origin_id'] == 'ABCD'
	assert m['model'] == 'Heltec V3'
	assert m['firmware_version'] == '1.17.1'
	assert m['client_version'].starts_with('meshbbs')
	assert m['timestamp'].starts_with('2025-10-09T08:53:20')
}
