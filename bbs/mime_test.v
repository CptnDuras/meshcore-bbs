module main

fn lf(s string) string {
	return s.replace('\n', '\r\n') // real mail has CRLF line endings
}

// ---- headers ----

fn test_headers_are_split_unfolded_and_lower_cased() {
	h := parse_headers('Subject: a long\r\n subject that\r\n\tfolds\r\nX-Thing: one\r\nx-thing: two\r\nFrom: ada@example.com')
	assert h['subject'] == ['a long subject that folds']
	assert h['x-thing'] == ['one', 'two']
	assert h['from'] == ['ada@example.com']
}

fn test_a_message_with_bare_lf_or_crlf_line_endings_splits_the_same_way() {
	for raw in ['A: 1\nB: 2\n\nbody text', 'A: 1\r\nB: 2\r\n\r\nbody text'] {
		h, b := split_message(raw)
		assert parse_headers(h)['b'] == ['2'] && b == 'body text'
	}
	h, b := split_message('only headers: here')
	assert h == 'only headers: here' && b == ''
}

fn test_a_line_that_is_not_a_header_is_skipped() {
	h := parse_headers('Good: yes\r\nthis is not a header\r\nAlso: yes\r\nBad Name: no')
	assert h['good'] == ['yes'] && h['also'] == ['yes']
	assert 'this is not a header' !in h && 'bad name' !in h
}

// ---- encodings ----

fn test_quoted_printable_and_base64_are_undone() {
	assert decode_qp('caf=C3=A9 =\r\nis good', false) == 'café is good'
	assert decode_qp('a=\nb=3Dc', false) == 'ab=c'
	assert decode_qp('hello_world', false) == 'hello_world'
	assert decode_qp('hello_world=21', true) == 'hello world!'
	assert decode_qp('100% = bad=ZZ', false) == '100% = bad=ZZ' // not an escape: left as it is
	assert decode_b64('Y2Fm\r\nw6k=') == 'café'
	assert decode_b64('Y2Fmw6k') == 'café' // missing padding
	assert decode_b64('not base64 !!!') == ''
}

fn test_other_charsets_become_utf8() {
	assert to_utf8('caf\xe9', 'iso-8859-1') == 'café'
	assert to_utf8('\x80 5', 'windows-1252') == '€ 5'
	assert to_utf8('caf\xc3\xa9', 'utf-8') == 'café'
	assert to_utf8('caf\xe9', 'utf-8') == 'café' // labelled UTF-8 but not: read as Windows-1252
	assert to_utf8('caf\xe9', 'x-unknown') == 'café'
	assert to_utf8('plain', '') == 'plain'
}

fn test_encoded_words_in_a_header_are_decoded() {
	assert decode_encoded_words('=?utf-8?B?Y2Fmw6k=?=') == 'café'
	assert decode_encoded_words('=?UTF-8?Q?caf=C3=A9_au_lait?=') == 'café au lait'
	assert decode_encoded_words('=?iso-8859-1?Q?caf=E9?=') == 'café'
	assert decode_encoded_words('Re: =?utf-8?B?Y2Fm?= =?utf-8?B?w6k=?= done') == 'Re: café done' // adjacent words join
	assert decode_encoded_words('plain subject') == 'plain subject'
	assert decode_encoded_words('broken =?utf-8?B?') == 'broken =?utf-8?B?' // left alone, not a crash
}

// ---- addresses ----

fn test_the_usual_ways_of_writing_a_sender() {
	cases := {
		'ada@example.com':                          ['ada@example.com', '']
		'Ada Lovelace <Ada@Example.COM>':           ['ada@example.com', 'Ada Lovelace']
		'"Lovelace, Ada" <ada@example.com>':        ['ada@example.com', 'Lovelace, Ada']
		'ada@example.com (Ada Lovelace)':           ['ada@example.com', 'Ada Lovelace']
		'=?utf-8?B?w4lsaXNl?= <elise@example.com>': ['elise@example.com', 'Élise']
		'<ada@example.com>':                        ['ada@example.com', '']
	}
	for raw, want in cases {
		a, n := parse_address(raw)
		assert a == want[0], raw
		assert n == want[1], raw
	}
}

fn test_things_that_are_not_one_sender_give_no_address() {
	for raw in ['', 'nobody', 'Ada <not an address>', '<>', 'a@b.co, c@d.co', 'a@b',
		'Ada <ada@example.com\r\nBcc: x@y.zz>'] {
		a, _ := parse_address(raw)
		assert a == '', raw
	}
}

// ---- whole messages ----

fn test_a_plain_message() {
	m := parse_mail(lf('From: Ada Lovelace <ada@example.com>\nSubject: Net tonight\nMessage-ID: <abc@example.com>\nContent-Type: text/plain; charset=utf-8\n\nNet at 7 on the usual channel.\nBring a radio.\n'))
	assert m.from_addr == 'ada@example.com' && m.from_name == 'Ada Lovelace'
	assert m.subject == 'Net tonight' && m.message_id == '<abc@example.com>'
	assert m.text == 'Net at 7 on the usual channel.\nBring a radio.' && m.dropped == 0 && !m.html_only
}

fn test_a_message_with_no_content_type_is_plain_text() {
	m := parse_mail('From: a@b.co\nSubject: x\n\nhello there')
	assert m.text == 'hello there'
}

fn test_plain_and_html_alternatives_use_the_plain_one() {
	m := parse_mail(lf('From: a@b.co
Subject: alt
Content-Type: multipart/alternative; boundary="XX"

--XX
Content-Type: text/plain; charset=utf-8

The plain words.
--XX
Content-Type: text/html; charset=utf-8

<html><body><p>The <b>html</b> words.</p></body></html>
--XX--
'))
	assert m.text == 'The plain words.' && !m.html_only && m.dropped == 0
}

fn test_a_message_that_is_only_html_is_reduced_to_its_words() {
	m := parse_mail(lf('From: a@b.co
Subject: html
Content-Type: text/html; charset=utf-8

<html><head><style>p{color:red}</style><title>t</title></head><body><script>alert(1)</script>
<p>Hello &amp; welcome, caf&#233;!</p><div>Line two<br>Line three</div><!-- hidden --></body></html>
'))
	assert m.html_only
	assert m.text.contains('Hello & welcome, café!') && m.text.contains('Line two\nLine three')
	assert !m.text.contains('alert') && !m.text.contains('color:red') && !m.text.contains('hidden') && !m.text.contains('<')
}

fn test_attachments_are_counted_and_left_out() {
	m := parse_mail(lf('From: a@b.co
Subject: pic
Content-Type: multipart/mixed; boundary="B1"

--B1
Content-Type: text/plain

See attached.
--B1
Content-Type: image/jpeg; name="x.jpg"
Content-Disposition: attachment; filename="x.jpg"
Content-Transfer-Encoding: base64

/9j/4AAQSkZJRgABAQEASABIAAD/2wBD
--B1
Content-Type: text/plain; name="notes.txt"
Content-Disposition: attachment; filename="notes.txt"

secret notes
--B1--
'))
	assert m.text == 'See attached.' && m.dropped == 2
	assert !m.text.contains('secret')
}

fn test_nested_multiparts_and_encodings() {
	m := parse_mail(lf('From: =?utf-8?B?w4lsaXNl?= <elise@example.com>
Subject: =?utf-8?Q?Caf=C3=A9_night?=
Content-Type: multipart/mixed; boundary="outer"

--outer
Content-Type: multipart/alternative; boundary="inner"

--inner
Content-Type: text/plain; charset=iso-8859-1
Content-Transfer-Encoding: quoted-printable

Caf=E9 at seven =
tonight.
--inner
Content-Type: text/html

<p>no</p>
--inner--
--outer--
'))
	assert m.from_name == 'Élise' && m.subject == 'Café night'
	assert m.text == 'Café at seven tonight.'
}

fn test_a_base64_body() {
	m := parse_mail(lf('From: a@b.co\nSubject: b64\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\nQ2Fmw6kgbmlnaHQ=\n'))
	assert m.text == 'Café night'
}

// ---- hostile and broken input ----

fn test_control_characters_and_odd_line_breaks_are_cleaned_from_the_text() {
	m := parse_mail('From: a@b.co\nSubject: x\n\nbell\x07 nul\x00 esc\x1b[31m red\r\n\r\n\r\n\r\n\r\nend\r\ttab\tstays')
	assert !m.text.contains('\x07') && !m.text.contains('\x00') && !m.text.contains('\x1b')
	assert !m.text.contains('\n\n\n') && !m.text.contains('\r')
	assert m.text.contains('\tstays')
}

fn test_a_subject_cannot_carry_a_line_break() {
	m := parse_mail('From: a@b.co\nSubject: first\n second\n\nx')
	assert !m.subject.contains('\n') && m.subject == 'first second'
	m2 := parse_mail('From: a@b.co\nSubject: =?utf-8?B?YQ0KQmNjOiBldmlsQHguY29t?=\n\nx') // "a\r\nBcc: evil@x.com"
	assert !m2.subject.contains('\r') && !m2.subject.contains('\n')
}

fn test_a_multipart_without_a_boundary_or_a_closing_one_does_not_crash() {
	a := parse_mail('From: a@b.co\nContent-Type: multipart/mixed\n\nhello')
	assert a.text == '' && a.dropped == 1
	b := parse_mail('From: a@b.co\nContent-Type: multipart/mixed; boundary=Z\n\n--Z\nContent-Type: text/plain\n\ncut short')
	assert b.text == 'cut short'
}

fn test_deeply_nested_and_many_part_messages_stop_where_they_should() {
	mut body := 'From: a@b.co\nContent-Type: multipart/mixed; boundary="b0"\n\n'
	for i in 0 .. 12 {
		body += '--b${i}\nContent-Type: multipart/mixed; boundary="b${i + 1}"\n\n'
	}
	body += '--b12\nContent-Type: text/plain\n\ndeep\n'
	m := parse_mail(body)
	assert m.text == '' // too deep to be real
	mut many := 'From: a@b.co\nContent-Type: multipart/mixed; boundary="M"\n\n'
	for _ in 0 .. 200 {
		many += '--M\nContent-Type: image/png\n\nx\n'
	}
	many += '--M--\n'
	pm := parse_mail(many)
	assert pm.dropped <= mime_max_parts + 1
}

fn test_empty_and_garbage_messages_parse_to_nothing() {
	for raw in ['', '\n\n', 'garbage with no headers at all', '\x00\x01\x02', 'From:\n\n'] {
		m := parse_mail(raw)
		assert m.from_addr == '', raw // whatever comes of the text, there is no sender, and nothing crashed
	}
}

fn test_the_receiving_services_headers_are_kept_for_the_policy() {
	m := parse_mail(lf('Received: from x\nX-SES-Spam-Verdict: PASS\nX-SES-Virus-Verdict: PASS\nAuthentication-Results: amazonses.com;\n spf=pass (spfCheck: domain of a.com designates 1.2.3.4) smtp.mailfrom=a.com;\n dkim=pass header.i=@a.com; dmarc=pass header.from=a.com\nReceived-SPF: pass\nFrom: a@b.co\n\nhi'))
	assert m.header('x-ses-spam-verdict') == 'PASS' && m.header('X-SES-Virus-Verdict') == 'PASS'
	assert m.header('authentication-results').contains('dkim=pass') && m.header('received-spf') == 'pass'
	assert m.header_all('received').len == 1 && m.header('nonexistent') == ''
}

fn test_html_stripping_handles_unclosed_and_odd_tags() {
	assert strip_html('a <b>bold</b> c') == 'a bold c'
	assert strip_html('x<script>never closed').trim_space() == 'x'
	assert strip_html('1 < 2 and 3 > 2') != '' // a stray < is not a tag that eats the rest
	assert strip_html('&lt;not a tag&gt; &amp; &unknown; &#65;') == '<not a tag> & &unknown; A'
}
