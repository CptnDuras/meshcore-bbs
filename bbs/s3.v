module main

import time

// The bucket SES drops incoming mail in, read the way ses.v sends: requests built and signed here (sigv4.v), sent by curl. Only three calls are needed:
// list what is waiting, fetch one message, delete it once it has been dealt with. The bucket is private to the account, and the daemon's key is allowed
// only those three things on the inbound prefix (tools/ses-inbound-setup.sh).

const empty_sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

struct ObjectInfo {
pub:
	key  string
	size int
}

// Where incoming mail waits. A port, so the worker can be tested with a fake bucket.
interface ObjectStore {
mut:
	list(limit int) ![]ObjectInfo
	get(key string) !string
	delete(key string) !
}

// A message's key is the prefix and the id SES gave it: letters, digits and - _ . only. Anything else (a name with a slash, "..", an XML entity) is not a
// message of ours and is never fetched or deleted.
fn valid_object_key(key string, prefix string) bool {
	if !key.starts_with(prefix) || key.len <= prefix.len || key.len > 200 || key.contains('..') {
		return false
	}
	return key[prefix.len..].bytes().all(it.is_alnum() || it in [`-`, `_`, `.`])
}

// percent-encoding as S3 canonical queries want it: letters, digits and - _ . ~ stay, everything else is %XX
fn uri_encode(s string) string {
	mut out := []u8{cap: s.len}
	for c in s.bytes() {
		if c.is_alnum() || c in [`-`, `_`, `.`, `~`] {
			out << c
		} else {
			out << `%`
			out << '0123456789ABCDEF'[c >> 4]
			out << '0123456789ABCDEF'[c & 15]
		}
	}
	return out.bytestr()
}

// A signed S3 request with no body. path is "/" or "/<key>"; query is already canonical (names sorted, values encoded).
fn s3_request(cfg SesConfig, method string, path string, query string, now i64) SesRequest {
	host := '${cfg.inbound_bucket}.s3.${cfg.region}.amazonaws.com'
	date := amz_date_of(now)
	signed := {
		'host':                 host
		'x-amz-content-sha256': empty_sha256
		'x-amz-date':           date
	}
	auth := sign_v4(AwsCreds{ access_key: cfg.access_key, secret_key: cfg.secret_key }, SignInput{
		method:   method
		path:     path
		query:    query
		headers:  signed
		region:   cfg.region
		service:  's3'
		amz_date: date
	})
	return SesRequest{
		url:     'https://${host}${path}${if query != '' { '?' + query } else { '' }}'
		headers: {
			'x-amz-content-sha256': empty_sha256
			'x-amz-date':           date
			'Authorization':        auth
		}
	}
}

// the text between <tag> and </tag> after position `from`, and where the closing tag ends; none if there is not one
fn xml_between(s string, tag string, from int) ?(string, int) {
	open := '<${tag}>'
	close := '</${tag}>'
	a := s.index_after(open, from) or { return none }
	b := s.index_after(close, a + open.len) or { return none }
	return s[a + open.len..b], b + close.len
}

// The messages in a ListObjectsV2 answer.
fn parse_object_list(xml string, prefix string) []ObjectInfo {
	mut out := []ObjectInfo{}
	mut at := 0
	for {
		block, next := xml_between(xml, 'Contents', at) or { break }
		at = next
		key, _ := xml_between(block, 'Key', 0) or { continue }
		size_text, _ := xml_between(block, 'Size', 0) or { '0', 0 }
		if !valid_object_key(key, prefix) {
			continue
		}
		out << ObjectInfo{
			key:  key
			size: size_text.int()
		}
	}
	return out
}

fn s3_error_text(status int, body string) string {
	msg, _ := xml_between(body, 'Message', 0) or { '', 0 }
	code, _ := xml_between(body, 'Code', 0) or { '', 0 }
	return 'S3 answered ${status}${if code != '' { ' ' + code } else { '' }}${if msg != '' {
		': ' + msg
	} else {
		''
	}}'
}

struct S3Store {
pub:
	cfg SesConfig
mut:
	sender HttpSender
}

fn (mut s S3Store) list(limit int) ![]ObjectInfo {
	q := 'list-type=2&max-keys=${limit}&prefix=${uri_encode(s.cfg.inbound_prefix)}'
	req := s3_request(s.cfg, 'GET', '/', q, time.now().unix())
	r := s.sender.request('GET', req.url, req.headers, '')
	if r.status != 200 {
		return error(if r.status == 0 {
			'no answer from S3'
		} else {
			s3_error_text(r.status, r.body)
		})
	}
	return parse_object_list(r.body, s.cfg.inbound_prefix)
}

fn (mut s S3Store) get(key string) !string {
	if !valid_object_key(key, s.cfg.inbound_prefix) {
		return error('not a message key: ${key}')
	}
	req := s3_request(s.cfg, 'GET', '/' + key, '', time.now().unix())
	r := s.sender.request('GET', req.url, req.headers, '')
	if r.status != 200 {
		return error(if r.status == 0 { 'no answer from S3' } else { s3_error_text(r.status, '') })
	}
	return r.body
}

// 404 counts as deleted: the aim is that it is gone
fn (mut s S3Store) delete(key string) ! {
	if !valid_object_key(key, s.cfg.inbound_prefix) {
		return error('not a message key: ${key}')
	}
	req := s3_request(s.cfg, 'DELETE', '/' + key, '', time.now().unix())
	r := s.sender.request('DELETE', req.url, req.headers, '')
	if r.status !in [200, 204, 404] {
		return error(if r.status == 0 {
			'no answer from S3'
		} else {
			s3_error_text(r.status, r.body)
		})
	}
}
