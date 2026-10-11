module main

// --- pagination.v coverage ---

fn test_paginate_short_single_page() {
	pages := paginate('hello world')
	assert pages.len == 1
	assert pages[0] == 'hello world'
}

fn test_paginate_splits_on_newlines_under_limit() {
	// many short lines that together exceed msg_max should split into pages
	mut text := ''
	for i in 0 .. 40 {
		text += 'line ${i}\n'
	}
	pages := paginate(text)
	assert pages.len > 1
	for p in pages {
		assert p.len <= msg_max
	}
}

fn test_paginate_hard_wraps_long_line() {
	long := 'x'.repeat(msg_max * 2 + 10)
	pages := paginate(long)
	// every page must be within the limit
	for p in pages {
		assert p.len <= msg_max
	}
	// reassembled length matches
	mut total := 0
	for p in pages {
		total += p.len
	}
	assert total == long.len
}

fn test_paginate_empty() {
	pages := paginate('')
	assert pages.len == 1
	assert pages[0] == ''
}

fn test_burst_within_cap_no_more() {
	pages := ['a', 'b']
	msgs, next, more := burst(pages, 0)
	assert msgs.len == 2
	assert next == 2
	assert more == false
}

fn test_burst_sends_all_pages_no_continue() {
	pages := ['a', 'b', 'c', 'd', 'e']
	msgs, next, more := burst(pages, 0)
	// every page is sent in one turn; no cap, no continue marker
	assert msgs.len == pages.len
	assert next == pages.len
	assert more == false
	for m in msgs {
		assert !m.contains('more')
	}
}

fn test_burst_respects_offset() {
	pages := ['a', 'b', 'c', 'd', 'e']
	msgs, next, more := burst(pages, 2)
	assert msgs.len == 3
	assert msgs[0] == 'c'
	assert next == pages.len
	assert more == false
}

// --- wx.v pure parsers coverage ---

fn test_extract_string_finds_value() {
	body := '{"a":1,"textDescription": "Clear","b":2}'
	assert extract_string(body, 'textDescription') == 'Clear'
}

fn test_extract_string_missing_key() {
	assert extract_string('{"x":1}', 'nope') == ''
}

fn test_extract_value_parses_nested_number() {
	body := '{"temperature": {"unitCode":"wmoUnit:degC","value": 12.5}}'
	v := extract_value(body, 'temperature') or {
		assert false, 'expected a value'
		return
	}
	assert v == 12.5
}

fn test_extract_value_null_returns_none() {
	body := '{"windSpeed": {"value": null}}'
	r := extract_value(body, 'windSpeed')
	assert r == none
}

fn test_extract_value_missing_key_none() {
	r := extract_value('{"a":1}', 'temperature')
	assert r == none
}

fn test_extract_value_negative() {
	body := '{"temperature": {"value": -2}}'
	v := extract_value(body, 'temperature') or {
		assert false, 'expected value'
		return
	}
	assert v == -2.0
}
