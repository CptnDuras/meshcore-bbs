module main

import os

// Weather via the US National Weather Service API (no key required).
// Fixed to Buffalo, WY -> station KBYG (Johnson County Airport).
//
// Implementation notes (V-on-FreeBSD gotchas we hit and worked around):
//   - V's net.http TLS path crashes (SIGPIPE) here, so we shell out to curl.
//   - x.json2 also crashed parsing the response here, so we extract the few
//     scalar fields we need with simple string parsing. The fields are stable
//     and few, so this is robust and dependency-free.
const wx_station = 'KBYG'
const wx_place = 'Buffalo, WY'
const wx_ua = 'meshbbs (steven.butler@gmail.com)'

pub fn fetch_weather() string {
	url := 'https://api.weather.gov/stations/${wx_station}/observations/latest'
	cmd := "curl -sf -m 15 -H 'User-Agent: ${wx_ua}' -H 'Accept: application/ld+json' '${url}'"
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return 'WX: could not reach weather service'
	}
	return format_weather(res.output)
}

// format_weather turns an NWS ld+json observation body into the terse WX line.
// Pure function (no I/O) so it is unit-testable with fixture strings.
fn format_weather(body string) string {
	mut parts := []string{}

	desc := extract_string(body, 'textDescription')
	if desc.len > 0 {
		parts << desc
	}
	if tc := extract_value(body, 'temperature') {
		tf := tc * 9.0 / 5.0 + 32.0
		parts << '${tf:.0f}F (${tc:.0f}C)'
	}
	if ws := extract_value(body, 'windSpeed') {
		mph := ws * 0.621371
		parts << 'wind ${mph:.0f}mph'
	}
	if rh := extract_value(body, 'relativeHumidity') {
		parts << 'hum ${rh:.0f}%'
	}
	if parts.len == 0 {
		return 'WX ${wx_place}: no current data'
	}
	return 'WX ${wx_place}: ' + parts.join(', ')
}

// extract_string finds "key": "value" and returns value (first match).
fn extract_string(body string, key string) string {
	needle := '"${key}":'
	idx := body.index(needle) or { return '' }
	mut i := idx + needle.len
	// skip whitespace
	for i < body.len && (body[i] == ` ` || body[i] == `\t` || body[i] == `\n`) {
		i++
	}
	if i >= body.len || body[i] != `"` {
		return ''
	}
	i++ // opening quote
	mut out := []u8{}
	for i < body.len && body[i] != `"` {
		out << body[i]
		i++
	}
	return out.bytestr()
}

// extract_value finds "key": { ... "value": <number|null> ... } and returns
// the number, or none if null/absent. NWS nests measurements as objects with a
// "value" field, so we locate the key then the next "value":.
fn extract_value(body string, key string) ?f64 {
	needle := '"${key}":'
	kidx := body.index(needle) or { return none }
	rest := body[kidx..]
	vneedle := '"value":'
	vidx := rest.index(vneedle) or { return none }
	mut i := vidx + vneedle.len
	for i < rest.len && (rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\n`) {
		i++
	}
	// collect the numeric token (digits, sign, dot, exponent)
	mut tok := []u8{}
	for i < rest.len {
		c := rest[i]
		if (c >= `0` && c <= `9`) || c == `-` || c == `+` || c == `.` || c == `e` || c == `E` {
			tok << c
			i++
		} else {
			break
		}
	}
	s := tok.bytestr()
	if s.len == 0 {
		return none // was null
	}
	return s.f64()
}
