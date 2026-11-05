module mqttcfg

fn test_the_report_address_must_be_https_and_plain() {
	assert valid_report_url('https://xerokuhl.com/planner-api/ingest') == ''
	assert valid_report_url(' https://example.org:8443/a/b~c ') == ''
	assert valid_report_url('http://xerokuhl.com/x').contains('https://')
	assert valid_report_url('xerokuhl.com').contains('https://')
	assert valid_report_url('https://').contains('host')
	assert valid_report_url('https:///path').contains('host')
}

fn test_a_report_address_cannot_carry_shell_characters() {
	for bad in ["https://x.com/a'b", 'https://x.com/a b', 'https://x.com/a;rm', 'https://x.com/$(id)',
		'https://x.com/a`b`', 'https://x.com/a"b', 'https://x.com/a&b', 'https://x.com/a|b',
		'https://x.com/a\nb'] {
		assert valid_report_url(bad) != '', bad
	}
}

fn test_a_token_is_long_printable_and_quote_free() {
	assert valid_report_token('a'.repeat(24))
	assert !valid_report_token('a'.repeat(23))
	assert !valid_report_token('a'.repeat(201))
	assert !valid_report_token('has space ' + 'a'.repeat(20))
	assert !valid_report_token("quote'" + 'a'.repeat(20))
	assert !valid_report_token('back\\slash' + 'a'.repeat(20))
	assert !valid_report_token('tab\t' + 'a'.repeat(20))
}

fn test_the_interval_is_kept_in_range() {
	assert report_minutes('') == 15
	assert report_minutes('abc') == 15
	assert report_minutes('0') == 15
	assert report_minutes('1') == 5
	assert report_minutes('30') == 30
	assert report_minutes('9999') == 120
}

fn test_a_position_is_both_or_neither() {
	_, _, given, err := parse_position('', ' ')
	assert !given
	assert err == ''
	la, lo, ok, e2 := parse_position('44.348', '-106.700')
	assert ok && e2 == ''
	assert la == 44.348 && lo == -106.7
	_, _, g3, e3 := parse_position('44.3', '')
	assert !g3 && e3.contains('both')
	_, _, _, e4 := parse_position('north', '-106')
	assert e4.contains('numbers')
	_, _, _, e5 := parse_position('91', '0')
	assert e5.contains('-90 to 90')
	_, _, z, e6 := parse_position('0', '0')
	assert z && e6 == '' // the equator and the meridian are places
}
