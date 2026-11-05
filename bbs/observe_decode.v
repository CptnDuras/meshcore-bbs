module main

import crypto.ed25519
import encoding.binary
import encoding.utf8

// What the planner report needs out of a heard packet: the path it came by and, for an advert, who sent it, what they are and where.
// Layout (MeshCore src/Packet.cpp, src/helpers/AdvertDataHelpers.h):
//   packet  = header(1) [transport codes(4)] path_len(1) path(hops*hash size) payload
//   advert  = public key(32) timestamp(4, little endian) signature(64) app data
//   app data = flags(1) [latitude(4) longitude(4), signed, millionths of a degree] [2] [2] [name, the rest]
//   flags    = bits 0-3 kind (1 chat, 2 repeater, 3 room, 4 sensor), 0x10 position, 0x20 and 0x40 two extra fields, 0x80 name
// The signature covers key + timestamp + app data. An advert whose signature does not check is thrown away: anyone with a radio can send one.

pub const payload_type_advert = 4
const adv_flag_position = 0x10
const adv_flag_extra1 = 0x20
const adv_flag_extra2 = 0x40
const adv_flag_name = 0x80
const advert_fixed = 32 + 4 + 64

// Heard is a packet split into the parts the report uses.
pub struct Heard {
pub:
	ptype     int
	hash_size int
	path      [][]u8 // one entry per hop, in the order the packet was forwarded
	payload   []u8
}

// split_packet cuts a raw packet into its path and payload. none for anything that does not parse.
pub fn split_packet(raw []u8) ?Heard {
	if raw.len < 3 {
		return none
	}
	header := raw[0]
	route_type := int(header & 0x03)
	mut i := 1
	if route_type == 0 || route_type == 3 { // transport codes present
		i += 4
	}
	if i >= raw.len {
		return none
	}
	path_len := raw[i]
	i++
	hops := int(path_len & 63)
	hash_size := int(path_len >> 6) + 1
	if hash_size == 4 || hops * hash_size > max_path_size {
		return none
	}
	if i + hops * hash_size >= raw.len { // at least one payload byte
		return none
	}
	mut path := [][]u8{}
	for _ in 0 .. hops {
		path << raw[i..i + hash_size].clone()
		i += hash_size
	}
	return Heard{
		ptype:     int((header >> 2) & 0x0F)
		hash_size: hash_size
		path:      path
		payload:   raw[i..].clone()
	}
}

// Advert is what a verified advert says about its sender.
pub struct Advert {
pub:
	pubkey    string // 64 hex, lower case
	timestamp i64
	role      string // chat | repeater | room | sensor
	name      string
	located   bool
	lat       f64
	lon       f64
}

// four bytes, little endian, as a signed number (a longitude west of Greenwich is negative)
fn signed_le32(b []u8) i64 {
	v := i64(binary.little_endian_u32(b))
	return if v >= 0x80000000 { v - 0x100000000 } else { v }
}

fn role_of(flags u8) string {
	return match flags & 0x0f {
		1 { 'chat' }
		2 { 'repeater' }
		3 { 'room' }
		4 { 'sensor' }
		else { '' }
	}
}

// parse_advert reads an advert payload and checks its signature. none when it is too short, malformed or forged.
pub fn parse_advert(payload []u8) ?Advert {
	if payload.len < advert_fixed + 1 {
		return none
	}
	key := payload[..32].clone()
	app := payload[advert_fixed..]
	mut signed := []u8{cap: 32 + 4 + app.len}
	signed << key
	signed << payload[32..36]
	signed << app
	ok := ed25519.verify(key, signed, payload[36..advert_fixed]) or { return none }
	if !ok {
		return none
	}
	flags := app[0]
	mut i := 1
	mut lat := 0.0
	mut lon := 0.0
	located := flags & adv_flag_position != 0
	if located {
		if i + 8 > app.len {
			return none
		}
		lat = f64(signed_le32(app[i..i + 4])) / 1000000.0
		lon = f64(signed_le32(app[i + 4..i + 8])) / 1000000.0
		i += 8
	}
	if flags & adv_flag_extra1 != 0 {
		i += 2
	}
	if flags & adv_flag_extra2 != 0 {
		i += 2
	}
	if i > app.len {
		return none
	}
	mut name := ''
	if flags & adv_flag_name != 0 {
		mut raw_name := app[i..].clone()
		z := raw_name.index(0)
		if z >= 0 {
			raw_name = raw_name[..z].clone()
		}
		name = raw_name.bytestr()
		if !utf8.validate_str(name) {
			name = '' // not text we can pass on
		}
	}
	return Advert{
		pubkey:    key.hex()
		timestamp: i64(binary.little_endian_u32(payload[32..36]))
		role:      role_of(flags)
		name:      name.trim_space()
		located:   located
		lat:       lat
		lon:       lon
	}
}
