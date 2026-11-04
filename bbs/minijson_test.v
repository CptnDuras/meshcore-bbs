module main

fn test_a_unicode_escape_is_decoded_to_utf8() {
	v := parse_json('{"a":"\\u0041","b":"caf\\u00e9","c":"\\u2019s","d":"x\\u0008y"}') or { panic('a \\u escape made the whole document fail') }
	assert v.str_of('a') == 'A'
	assert v.str_of('b') == 'café'
	assert v.str_of('c') == '’s'
	assert v.str_of('d') == 'x\x08y'
}

fn test_a_document_with_an_escape_in_the_middle_still_parses_the_rest() {
	v := parse_json('{"event":"Tornado Warning","headline":"Issued by NWS Billings \\u2014 until 5 PM","next":"ok"}') or { panic('not parsed') }
	assert v.str_of('event') == 'Tornado Warning'
	assert v.str_of('next') == 'ok'
}

fn test_a_truncated_or_bad_escape_is_rejected_not_a_crash() {
	assert parse_json('{"a":"\\u00"}') == none
	assert parse_json('{"a":"\\uzzzz"}') == none
}

fn test_the_usual_escapes_and_nesting_still_work() {
	v := parse_json('{"o":{"k":["a\\n","b\\"c"]},"n":12,"t":true,"z":null}') or { panic('not parsed') }
	assert v.get('o').get('k').arr.map(it.s) == ['a\n', 'b"c']
	assert v.get('n').s == '12' && v.get('t').s == 'true'
}
