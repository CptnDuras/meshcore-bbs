module main

import os

// Space weather via NOAA SWPC (no key required).
//
// Same FreeBSD-driven constraints as wx.v: V's net.http TLS path and x.json2
// crash here, so we shell out to curl and extract the few scalar fields we
// need with simple string parsing. Parsing is split into pure functions that
// take a response body string, so they can be unit-tested offline.
//
// Sources:
//   K-index (planetary):  services.swpc.noaa.gov/products/noaa-planetary-k-index.json
//   10.7cm solar flux:    services.swpc.noaa.gov/json/f107_cm_flux.json
//   NOAA scales (R/S/G):  services.swpc.noaa.gov/products/noaa-scales.json
const swpc_ua = 'meshbbs (steven.butler@gmail.com)'
const swpc_kp_url = 'https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json'
const swpc_flux_url = 'https://services.swpc.noaa.gov/json/f107_cm_flux.json'
const swpc_scales_url = 'https://services.swpc.noaa.gov/products/noaa-scales.json'

pub fn fetch_spacewx() string {
	kp_body := curl_get(swpc_kp_url, swpc_ua)
	flux_body := curl_get(swpc_flux_url, swpc_ua)
	scales_body := curl_get(swpc_scales_url, swpc_ua)
	return format_spacewx(kp_body, flux_body, scales_body)
}

// curl_get fetches a URL with the given UA, returning '' on failure.
// Shared by the SWPC and news pollers (V http TLS crashes here, so we shell
// out to curl exactly like wx.v does).
fn curl_get(url string, ua string) string {
	cmd := "curl -sf -m 15 -H 'User-Agent: ${ua}' '${url}'"
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return ''
	}
	return res.output
}

// format_spacewx builds the report string from the three response bodies.
// Pure function (no I/O) so it is unit-testable with fixture strings.
fn format_spacewx(kp_body string, flux_body string, scales_body string) string {
	mut parts := []string{}

	if kp := last_number(kp_body, '"Kp":') {
		parts << 'Kp ${kp:.1f} (${kp_word(kp)})'
	}
	if flux := last_number(flux_body, '"flux":') {
		parts << 'SFI ${flux:.0f}'
	}
	// Current NOAA scales live under the "0" key; grab the R/S/G Text values.
	rscale := scale_text(scales_body, 'R')
	sscale := scale_text(scales_body, 'S')
	gscale := scale_text(scales_body, 'G')
	if rscale.len > 0 || sscale.len > 0 || gscale.len > 0 {
		parts << 'R:${or_none(rscale)} S:${or_none(sscale)} G:${or_none(gscale)}'
	}

	if parts.len == 0 {
		return 'SPACEWX: could not reach SWPC'
	}
	return 'SPACEWX: ' + parts.join(', ')
}

fn or_none(s string) string {
	return if s.len == 0 { 'none' } else { s }
}

// kp_word gives a terse condition label for a Kp value.
fn kp_word(kp f64) string {
	if kp < 4.0 {
		return 'quiet'
	}
	if kp < 5.0 {
		return 'unsettled'
	}
	if kp < 6.0 {
		return 'minor storm'
	}
	if kp < 7.0 {
		return 'moderate storm'
	}
	return 'strong+ storm'
}

// last_number finds the LAST occurrence of `key` in body and returns the
// numeric token that follows it. SWPC time series are chronological, so the
// last entry is the most recent. Handles scientific notation (1.48e+002).
fn last_number(body string, key string) ?f64 {
	if body.len == 0 {
		return none
	}
	idx := body.last_index(key) or { return none }
	mut i := idx + key.len
	// skip whitespace
	for i < body.len && (body[i] == ` ` || body[i] == `\t` || body[i] == `\n`) {
		i++
	}
	mut tok := []u8{}
	for i < body.len {
		c := body[i]
		if (c >= `0` && c <= `9`) || c == `-` || c == `+` || c == `.` || c == `e` || c == `E` {
			tok << c
			i++
		} else {
			break
		}
	}
	s := tok.bytestr()
	if s.len == 0 {
		return none
	}
	return s.f64()
}

// scale_text extracts the current (key "0") R/S/G scale "Text" from the
// noaa-scales.json body. The structure is:
//   {"0": {..., "R": {"Scale": "0", "Text": "none", ...}, "S": {...}, "G": {...}}, "1": {...}}
// We take the first "<letter>": { ... "Text": "..." } which belongs to the "0"
// (current) block since it appears first in the document.
fn scale_text(body string, letter string) string {
	if body.len == 0 {
		return ''
	}
	needle := '"${letter}":'
	idx := body.index(needle) or { return '' }
	rest := body[idx..]
	tneedle := '"Text":'
	tidx := rest.index(tneedle) or { return '' }
	mut i := tidx + tneedle.len
	for i < rest.len && (rest[i] == ` ` || rest[i] == `\t` || rest[i] == `\n`) {
		i++
	}
	if i >= rest.len {
		return ''
	}
	// value may be null or a quoted string
	if rest[i] == `n` { // null
		return ''
	}
	if rest[i] != `"` {
		return ''
	}
	i++
	mut out := []u8{}
	for i < rest.len && rest[i] != `"` {
		out << rest[i]
		i++
	}
	txt := out.bytestr()
	// "none" is meaningful (no activity); return it as-is.
	return txt
}
