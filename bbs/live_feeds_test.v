module main

import os

// Live integration tests for the network-backed data services. These hit the
// real internet, so they are GATED behind an env flag and skip by default —
// they never fail offline or in CI. Enable with:
//
//   MESHBBS_LIVE_TESTS=1 v test ./bbs
//
// When enabled, they assert the live output is well-formed (not the failure
// fallback string), which validates the curl + parser path end-to-end.

fn live_enabled() bool {
	return os.getenv('MESHBBS_LIVE_TESTS') == '1'
}

fn test_live_weather() {
	if !live_enabled() {
		eprintln('[skip] live weather (set MESHBBS_LIVE_TESTS=1 to run)')
		return
	}
	out := fetch_weather()
	eprintln('LIVE WX => ${out}')
	assert out.starts_with('WX ')
	// must have reached the service (not the connection-failure fallback)
	assert !out.contains('could not reach')
}

fn test_live_spacewx() {
	if !live_enabled() {
		eprintln('[skip] live spacewx (set MESHBBS_LIVE_TESTS=1 to run)')
		return
	}
	out := fetch_spacewx()
	eprintln('LIVE SPACEWX => ${out}')
	assert out.starts_with('SPACEWX:')
	assert !out.contains('could not reach')
}

fn test_live_news() {
	if !live_enabled() {
		eprintln('[skip] live news (set MESHBBS_LIVE_TESTS=1 to run)')
		return
	}
	out := fetch_news()
	eprintln('LIVE NEWS =>\n${out}')
	assert out.contains('Local News')
	assert !out.contains('could not reach')
}
