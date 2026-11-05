module main

import net
import time

fn test_an_https_url_is_split_into_host_port_and_path() ? {
	t := parse_https_url('https://Email.US-West-2.amazonaws.com/v2/email/outbound-emails')?
	assert t.host == 'email.us-west-2.amazonaws.com' && t.port == 443 && t.path == '/v2/email/outbound-emails'
	u := parse_https_url('https://bucket.s3.us-west-2.amazonaws.com?list-type=2&prefix=inbound%2F')?
	assert u.path == '/' || u.path.starts_with('/') // a bare host still has a path
	v := parse_https_url('https://localhost:18443/obj?x=1#frag')?
	assert v.host == 'localhost' && v.port == 18443 && v.path == '/obj?x=1'
}

fn test_anything_that_is_not_a_plain_https_url_is_refused() {
	for bad in ['http://example.com/', 'ftp://example.com/', 'https://', 'https:///x',
		'https://user:pw@example.com/', 'https://example.com:0/', 'https://example.com:99999/',
		'https://example.com:80a/', 'https://exa mple.com/', 'https://example.com/a\r\nHost: evil',
		'https://[::1]/', 'example.com'] {
		assert parse_https_url(bad) == none, bad
	}
}

fn test_the_request_has_the_lines_this_client_owns_and_the_callers_headers() ? {
	t := parse_https_url('https://example.com:8443/p?q=1')?
	r := build_http_request('POST', t, {
		'Content-Type':   'application/json'
		'Authorization':  'AWS4-HMAC-SHA256 x'
		'Host':           'evil.example'
		'content-length': '5'
		'Connection':     'keep-alive'
	}, '{"a":1}')?
	assert r.starts_with('POST /p?q=1 HTTP/1.1\r\nHost: example.com:8443\r\nConnection: close\r\n')
	assert r.contains('Content-Type: application/json\r\n') && r.contains('Authorization: AWS4-HMAC-SHA256 x\r\n')
	assert !r.contains('evil.example') && !r.contains('keep-alive') && !r.contains('Content-Length: 5')
	assert r.contains('Content-Length: 7\r\n\r\n{"a":1}') && r.ends_with('\r\n\r\n{"a":1}')
	g := build_http_request('GET', parse_https_url('https://example.com/x')?, map[string]string{}, '')?
	assert g.starts_with('GET /x HTTP/1.1\r\nHost: example.com\r\n') && !g.contains('Content-Length') && g.ends_with('\r\n\r\n')
}

fn test_a_header_that_could_start_another_is_refused() ? {
	t := parse_https_url('https://example.com/')?
	assert build_http_request('GET', t, {
		'X-A': 'one\r\nX-Injected: yes'
	}, '') == none
	assert build_http_request('GET', t, {
		'X-A\r\nX-B': 'one'
	}, '') == none
	assert build_http_request('GET', t, {
		'': 'one'
	}, '') == none
	assert build_http_request('PUT', t, map[string]string{}, '') == none
}

fn test_the_head_is_read_when_it_is_all_there() ? {
	assert parse_response_head('HTTP/1.1 200 OK\r\nContent-Le'.bytes()) == none
	h := parse_response_head('HTTP/1.1 404 Not Found\r\nContent-Length: 12\r\nX-A: b\r\n\r\nbody'.bytes())?
	assert h.status == 404 && h.length == 12 && !h.chunked && h.body_at == 54
	c := parse_response_head('HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\n\r\n'.bytes())?
	assert c.status == 200 && c.chunked && c.length == -1
	n := parse_response_head('garbage\r\n\r\n'.bytes())?
	assert n.status == 0
	w := parse_response_head('HTTP/1.1 20 OK\r\n\r\n'.bytes())?
	assert w.status == 0
	big := parse_response_head('HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n'.bytes())?
	assert big.length == -1
}

fn test_a_chunked_body_is_put_together_and_waits_for_the_last_chunk() ? {
	whole := '5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n'.bytes()
	assert decode_chunked(whole)?.bytestr() == 'hello world'
	assert decode_chunked('5\r\nhello\r\n6\r\n wor'.bytes()) == none // more to come
	assert decode_chunked('5\r\nhello\r\n'.bytes()) == none
	assert decode_chunked('zz\r\nhello\r\n0\r\n\r\n'.bytes()) == none // not hex
	assert decode_chunked('FFFFFFFFF\r\n'.bytes()) == none // too long to be a size
	assert decode_chunked('0\r\n\r\n'.bytes())?.len == 0
	assert decode_chunked('a\r\n0123456789\r\n0\r\n\r\n'.bytes())?.bytestr() == '0123456789'
}

fn test_the_body_is_complete_by_length_by_chunks_or_by_status() ? {
	raw := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel'.bytes()
	h := parse_response_head(raw)?
	assert complete_body(raw, h) == none
	full := 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello!!'.bytes()
	assert complete_body(full, parse_response_head(full)?)?.bytestr() == 'hello' // only what it says
	none_ := 'HTTP/1.1 204 No Content\r\n\r\n'.bytes()
	assert complete_body(none_, parse_response_head(none_)?)?.len == 0
	open := 'HTTP/1.1 200 OK\r\n\r\nuntil close'.bytes()
	assert complete_body(open, parse_response_head(open)?) == none // only the close says it is whole
	ch := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n'.bytes()
	assert complete_body(ch, parse_response_head(ch)?)?.bytestr() == 'abc'
}

fn test_dialing_a_port_that_answers_gives_a_connection_and_a_closed_one_fails_fast() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { return } // no sockets here: nothing to test
	port := l.addr()!.port()!
	mut c := dial_within('127.0.0.1', int(port), 3 * time.second)!
	c.close() or {}
	l.close() or {}
	t := time.now()
	dial_within('127.0.0.1', int(port), 3 * time.second) or {
		assert time.since(t) < 2 * time.second
		assert err.msg().len > 0
		return
	}
	assert false, 'a closed port connected'
}
