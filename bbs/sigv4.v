module main

import crypto.hmac
import crypto.sha256
import encoding.hex
import time

// AWS Signature Version 4, just enough to call SES with no SDK. Ported from the planner service's aws.v (same author, same tests): this daemon cannot
// use V's TLS, so the request is signed here and sent by httpclient.v.

struct AwsCreds {
	access_key string
	secret_key string
}

fn hmac_sha256(key []u8, data string) []u8 {
	return hmac.new(key, data.bytes(), sha256.sum256, sha256.block_size)
}

fn sha256_hex(data string) string {
	return hex.encode(sha256.sum256(data.bytes()))
}

fn signing_key(secret string, date string, region string, service string) []u8 {
	k_date := hmac_sha256('AWS4${secret}'.bytes(), date)
	k_region := hmac_sha256(k_date, region)
	k_service := hmac_sha256(k_region, service)
	return hmac_sha256(k_service, 'aws4_request')
}

// What goes into one signature. headers: every header to be signed, names in lower case (host is always among them).
struct SignInput {
	method   string
	path     string
	query    string // already in canonical form: names and values percent-encoded, sorted by name
	headers  map[string]string
	body     string
	region   string
	service  string
	amz_date string // 20150830T123600Z
}

fn canonical_request(in_ SignInput) (string, string) {
	mut names := in_.headers.keys()
	names.sort()
	mut canon := ''
	for n in names {
		canon += '${n}:${in_.headers[n].trim_space()}\n'
	}
	signed := names.join(';')
	return [in_.method, in_.path, in_.query, canon, signed, sha256_hex(in_.body)].join('\n'), signed
}

// -> the Authorization header's value
fn sign_v4(creds AwsCreds, in_ SignInput) string {
	date := in_.amz_date[..8]
	scope := '${date}/${in_.region}/${in_.service}/aws4_request'
	canon, signed := canonical_request(in_)
	to_sign := 'AWS4-HMAC-SHA256\n${in_.amz_date}\n${scope}\n${sha256_hex(canon)}'
	key := signing_key(creds.secret_key, date, in_.region, in_.service)
	sig := hex.encode(hmac_sha256(key, to_sign))
	return 'AWS4-HMAC-SHA256 Credential=${creds.access_key}/${scope}, SignedHeaders=${signed}, Signature=${sig}'
}

fn amz_date_of(unix i64) string {
	t := time.unix(unix).local_to_utc()
	return '${t.year:04}${t.month:02}${t.day:02}T${t.hour:02}${t.minute:02}${t.second:02}Z'
}
