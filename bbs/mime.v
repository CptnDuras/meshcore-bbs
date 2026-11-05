module main

import encoding.base64
import encoding.utf8

// Reading one incoming email (RFC 5322 + MIME) into what the list needs: who sent it, the subject, the plain text, and the headers that decide whether
// to pass it on. Anything a stranger can put in a message is untrusted, so this never trusts a length or a charset name, handles a malformed message
// by returning less (never by crashing), and sends out only text: attachments are counted and dropped, HTML is reduced to its words.

const mime_max_depth = 6
const mime_max_parts = 40

struct ParsedMail {
pub mut:
	headers    map[string][]string // names in lower case; a header that appears several times keeps every value, in order
	from_addr  string              // lower case, '' if there is none or it is not an address
	from_name  string
	subject    string
	message_id string
	text       string // the plain text of the message, HTML reduced to words if that is all there was
	dropped    int    // attachments and other parts that are not text, left out
	html_only  bool   // the text came from an HTML part
}

// the first value of a header, or ''
fn (m ParsedMail) header(name string) string {
	v := m.headers[name.to_lower()] or { return '' }
	return if v.len > 0 { v[0] } else { '' }
}

fn (m ParsedMail) header_all(name string) []string {
	return m.headers[name.to_lower()] or { []string{} }
}

// The header block and the body, split at the first empty line (CRLF or bare LF).
fn split_message(raw string) (string, string) {
	crlf := raw.index('\r\n\r\n') or { -1 }
	lf := raw.index('\n\n') or { -1 }
	if crlf >= 0 && (lf < 0 || crlf < lf) {
		return raw[..crlf], raw[crlf + 4..]
	}
	if lf >= 0 {
		return raw[..lf], raw[lf + 2..]
	}
	return raw, ''
}

// Header lines into names (lower case) and values, with folded lines joined by a single space.
fn parse_headers(block string) map[string][]string {
	mut out := map[string][]string{}
	mut name := ''
	mut value := ''
	for raw_line in block.replace('\r\n', '\n').split('\n') {
		if raw_line.len > 0 && (raw_line[0] == ` ` || raw_line[0] == `\t`) {
			if name != '' {
				value += ' ' + raw_line.trim_space()
			}
			continue
		}
		if name != '' {
			out[name] << value.trim_space()
		}
		name = ''
		value = ''
		colon := raw_line.index(':') or { continue }
		n := raw_line[..colon].trim_space().to_lower()
		if n == '' || n.contains(' ') {
			continue
		}
		name = n
		value = raw_line[colon + 1..]
	}
	if name != '' {
		out[name] << value.trim_space()
	}
	return out
}

// ---- text encodings ----

// the 0x80..0x9f range of Windows-1252, which is not Latin-1
const cp1252_high = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030,
	0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013,
	0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]

fn single_byte_to_utf8(b string, cp1252 bool) string {
	mut out := []u8{cap: b.len + b.len / 4}
	for c in b.bytes() {
		if c < 0x80 {
			out << c
		} else {
			cp := if cp1252 && c < 0xA0 { u32(cp1252_high[int(c) - 0x80]) } else { u32(c) }
			out << utf32_to_str(cp).bytes()
		}
	}
	return out.bytestr()
}

// Text in the named charset as UTF-8. UTF-8 and ASCII are checked rather than believed: bytes that are not valid UTF-8 are read as Windows-1252, which is
// what a mislabelled message nearly always is. A charset this does not know is read the same way.
fn to_utf8(body string, charset string) string {
	cs := charset.trim_space().trim('"').to_lower()
	if cs in ['iso-8859-1', 'latin1', 'l1', 'iso8859-1'] {
		return single_byte_to_utf8(body, false)
	}
	if cs in ['windows-1252', 'cp1252', 'iso-8859-15'] {
		return single_byte_to_utf8(body, true)
	}
	if utf8.validate_str(body) {
		return body
	}
	return single_byte_to_utf8(body, true)
}

fn hex_val(c u8) int {
	return if c >= `0` && c <= `9` {
		int(c) - int(`0`)
	} else if c >= `a` && c <= `f` {
		int(c) - int(`a`) + 10
	} else if c >= `A` && c <= `F` {
		int(c) - int(`A`) + 10
	} else {
		-1
	}
}

// Quoted-printable. `q_word` is the header form, where an underscore is a space.
fn decode_qp(s string, q_word bool) string {
	mut out := []u8{cap: s.len}
	b := s.bytes()
	mut i := 0
	for i < b.len {
		c := b[i]
		if c == `=` {
			if i + 1 < b.len && b[i + 1] == `\n` {
				i += 2
				continue
			}
			if i + 2 < b.len && b[i + 1] == `\r` && b[i + 2] == `\n` {
				i += 3
				continue
			}
			if i + 2 < b.len {
				h := hex_val(b[i + 1])
				l := hex_val(b[i + 2])
				if h >= 0 && l >= 0 {
					out << u8(h * 16 + l)
					i += 3
					continue
				}
			}
			out << c
			i++
			continue
		}
		out << if q_word && c == `_` { u8(` `) } else { c }
		i++
	}
	return out.bytestr()
}

fn decode_b64(s string) string {
	mut t := s.replace('\r', '').replace('\n', '').replace(' ', '').replace('\t', '')
	if t.len == 0 || t.bytes().any(!(it.is_alnum() || it in [`+`, `/`, `=`])) {
		return ''
	}
	for t.len % 4 != 0 {
		t += '='
	}
	return base64.decode_str(t)
}

// The body of a part, undone from its transfer encoding.
fn decode_transfer(body string, enc string) string {
	return match enc.trim_space().to_lower() {
		'base64' { decode_b64(body) }
		'quoted-printable' { decode_qp(body, false) }
		else { body }
	}
}

// RFC 2047 "encoded words" in a header (=?utf-8?B?...?= and =?iso-8859-1?Q?...?=), as UTF-8. Words next to each other are joined without the space between.
fn decode_encoded_words(s string) string {
	mut out := ''
	mut rest := s
	mut last_was_word := false
	for {
		start := rest.index('=?') or { break }
		// =?charset?enc?text?=
		after := rest[start + 2..]
		q1 := after.index('?') or { break }
		if after.len < q1 + 4 {
			break
		}
		charset := after[..q1]
		enc := after[q1 + 1..q1 + 2].to_lower()
		if after[q1 + 2] != `?` {
			out += rest[..start + 2]
			rest = after
			last_was_word = false
			continue
		}
		end := after[q1 + 3..].index('?=') or { break }
		text := after[q1 + 3..q1 + 3 + end]
		between := rest[..start]
		out += if last_was_word && between.trim_space() == '' { '' } else { between }
		raw := match enc {
			'b' { decode_b64(text) }
			'q' { decode_qp(text, true) }
			else { text }
		}
		out += to_utf8(raw, charset)
		rest = after[q1 + 3 + end + 2..]
		last_was_word = true
	}
	return out + rest
}

// ---- addresses ----

// "Ada Lovelace <ada@example.com>", "ada@example.com (Ada)", "\"Lovelace, Ada\" <ada@example.com>" or a bare address: the lower-cased address and the name.
// '' for the address when it is not one (the caller decides what to do with such a message).
fn parse_address(raw string) (string, string) {
	s := decode_encoded_words(raw).trim_space()
	if s.contains('<') && s.contains('>') {
		addr := s.all_after_last('<').all_before('>').trim_space().to_lower()
		name := s.all_before_last('<').trim_space().trim('"').trim_space()
		return if is_plain_address(addr) { addr } else { '' }, clean_text_line(name)
	}
	if s.contains('(') && s.contains(')') {
		addr := s.all_before('(').trim_space().to_lower()
		name := s.all_after('(').all_before_last(')')
		return if is_plain_address(addr) { addr } else { '' }, clean_text_line(name)
	}
	addr := s.to_lower()
	return if is_plain_address(addr) { addr } else { '' }, ''
}

fn is_plain_address(a string) bool {
	return a.len >= 3 && a.len <= 254 && a.count('@') == 1 && !a.contains(' ') && !a.contains(',') && !a.contains('<') && !a.contains('>')
		&& !a.contains('"') && a.bytes().all(it >= 32 && it != 127) && a.all_after('@').contains('.')
}

// one line of plain text: control characters and line breaks removed
fn clean_text_line(s string) string {
	return s.bytes().filter(it >= 32 && it != 127).bytestr().trim_space()
}

// ---- content types ----

struct ContentType {
mut:
	typ    string // lower case "text/plain"
	params map[string]string
}

fn parse_content_type(raw string) ContentType {
	mut ct := ContentType{
		typ: 'text/plain'
	}
	if raw.trim_space() == '' {
		return ct
	}
	parts := raw.split(';')
	ct.typ = parts[0].trim_space().to_lower()
	for p in parts[1..] {
		eq := p.index('=') or { continue }
		ct.params[p[..eq].trim_space().to_lower()] = p[eq + 1..].trim_space().trim('"')
	}
	return ct
}

// ---- reducing HTML to words ----

fn html_entity(e string) string {
	return match e {
		'amp' { '&' }
		'lt' { '<' }
		'gt' { '>' }
		'quot' { '"' }
		'apos', '#39' { "'" }
		'nbsp' { ' ' }
		else { '' }
	}
}

fn strip_html(h string) string {
	mut s := h
	// whole blocks that carry no words
	for tag in ['script', 'style', 'head'] {
		for {
			lo := s.to_lower()
			a := lo.index('<${tag}') or { break }
			b := lo.index('</${tag}>') or {
				s = s[..a]
				break
			}
			s = s[..a] + s[b + tag.len + 3..]
		}
	}
	for {
		a := s.index('<!--') or { break }
		b := s[a..].index('-->') or {
			s = s[..a]
			break
		}
		s = s[..a] + s[a + b + 3..]
	}
	mut out := []u8{cap: s.len}
	b := s.bytes()
	mut i := 0
	for i < b.len {
		c := b[i]
		if c == `<` {
			end := s.index_after('>', i) or { break }
			tag := s[i + 1..end].to_lower().trim_space().trim_left('/')
			name := tag.all_before(' ').all_before('/')
			if name in ['br', 'p', 'div', 'tr', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote'] {
				out << `\n`
			}
			i = end + 1
			continue
		}
		if c == `&` {
			if semi := s.index_after(';', i) {
				if semi - i <= 8 {
					ent := s[i + 1..semi]
					rep := if ent.starts_with('#') && ent.len > 1 && ent[1..].bytes().all(it.is_digit()) {
						utf32_to_str(u32(ent[1..].int()))
					} else {
						html_entity(ent)
					}
					if rep != '' || ent in ['amp', 'lt', 'gt', 'quot', 'apos', 'nbsp'] {
						out << rep.bytes()
						i = semi + 1
						continue
					}
				}
			}
		}
		out << c
		i++
	}
	return out.bytestr()
}

// Text safe to put in an email we send: line endings as \n, no control characters other than a tab, no runs of blank lines, trimmed.
fn clean_body_text(s string) string {
	mut lines := []string{}
	mut blank := 0
	for raw in s.replace('\r\n', '\n').replace('\r', '\n').split('\n') {
		line := raw.bytes().filter(it == `\t` || (it >= 32 && it != 127)).bytestr().trim_right(' \t')
		if line == '' {
			blank++
			if blank > 1 {
				continue
			}
		} else {
			blank = 0
		}
		lines << line
	}
	return lines.join('\n').trim_space()
}

// ---- walking the parts ----

struct TextFound {
mut:
	plain   string
	html    string
	dropped int
	parts   int
}

fn (mut t TextFound) walk(headers map[string][]string, body string, depth int) {
	t.parts++
	if depth > mime_max_depth || t.parts > mime_max_parts {
		t.dropped++
		return
	}
	ct := parse_content_type(first_header(headers, 'content-type'))
	disp := first_header(headers, 'content-disposition').to_lower()
	if ct.typ.starts_with('multipart/') {
		boundary := ct.params['boundary'] or { '' }
		if boundary == '' {
			t.dropped++
			return
		}
		for piece in split_multipart(body, boundary) {
			if t.parts > mime_max_parts {
				t.dropped++ // far more parts than any real message has: stop reading, do not walk them all
				break
			}
			ph, pb := split_message(piece)
			t.walk(parse_headers(ph), pb, depth + 1)
		}
		return
	}
	if disp.starts_with('attachment') || !(ct.typ == 'text/plain' || ct.typ == 'text/html') {
		t.dropped++
		return
	}
	enc := first_header(headers, 'content-transfer-encoding')
	text := to_utf8(decode_transfer(body, enc), ct.params['charset'] or { 'utf-8' })
	if ct.typ == 'text/plain' {
		if t.plain == '' {
			t.plain = text
		}
	} else if t.html == '' {
		t.html = text
	}
}

fn first_header(h map[string][]string, name string) string {
	v := h[name] or { return '' }
	return if v.len > 0 { v[0] } else { '' }
}

// The pieces between "--boundary" lines. Anything before the first or after the closing "--boundary--" is not a part.
fn split_multipart(body string, boundary string) []string {
	delim := '--' + boundary
	mut pieces := []string{}
	mut current := []string{}
	mut inside := false
	for raw in body.replace('\r\n', '\n').split('\n') {
		line := raw.trim_right(' \t')
		if line == delim || line == delim + '--' {
			if inside {
				pieces << current.join('\n')
			}
			current = []string{}
			inside = line == delim
			continue
		}
		if inside {
			current << raw
		}
	}
	if inside && current.len > 0 {
		pieces << current.join('\n') // a message cut short is still read as far as it goes
	}
	return pieces
}

// An incoming message, read. Never fails: a message that cannot be read comes back with little or no text.
fn parse_mail(raw string) ParsedMail {
	hblock, body := split_message(raw)
	headers := parse_headers(hblock)
	mut m := ParsedMail{
		headers: headers
	}
	m.from_addr, m.from_name = parse_address(first_header(headers, 'from'))
	m.subject = clean_text_line(decode_encoded_words(first_header(headers, 'subject')))
	m.message_id = clean_text_line(first_header(headers, 'message-id'))
	mut t := TextFound{}
	t.walk(headers, body, 0)
	m.dropped = t.dropped
	if t.plain.trim_space() != '' {
		m.text = clean_body_text(t.plain)
	} else if t.html.trim_space() != '' {
		m.text = clean_body_text(strip_html(t.html))
		m.html_only = true
	}
	return m
}
