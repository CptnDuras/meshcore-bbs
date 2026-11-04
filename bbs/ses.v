module main

import emaillist
import encoding.utf8
import os

// Sending email through Amazon SES (the v2 API), with no SDK and no V TLS: the request is built and signed here (sigv4.v) and handed to curl.
//
// The pieces are separate so each can be tested alone: parse_ses_config (the settings file), ses_request (a pure function from a message to the signed
// request), classify_ses_reply (what an answer means for the message and for the queue), and CurlSender (the only part that touches the network).

// SesConfig is read from a file only the daemon's user can read (it holds an access key):
//   region=us-west-2
//   access_key_id=AKIA...
//   secret_access_key=...
//   from=mesh@xerokuhl.com
//   from_name=Buffalo Mesh          (optional)
//   configuration_set=meshbbs       (optional)
//   reply_to=someone@example.com    (optional)
struct SesConfig {
pub:
	region     string = 'us-west-2'
	access_key string
	secret_key string
	from_addr  string
	from_name  string
	config_set string
	reply_to   string
}

fn parse_ses_config(text string) !SesConfig {
	mut kv := map[string]string{}
	for raw in text.split('\n') {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') || !line.contains('=') {
			continue
		}
		kv[line.all_before('=').trim_space().to_lower()] = line.all_after('=').trim_space()
	}
	for k, v in kv {
		if !emaillist.plain_value(v) {
			return error('the SES settings value for ${k} has a control character in it')
		}
	}
	region := kv['region'] or { 'us-west-2' }
	if region == '' || !region.bytes().all((it >= `a` && it <= `z`) || it.is_digit() || it == `-`) {
		return error('the SES region is not a region name')
	}
	key := kv['access_key_id'] or { '' }
	secret := kv['secret_access_key'] or { '' }
	if key == '' || secret == '' {
		return error('the SES settings need access_key_id and secret_access_key')
	}
	from := kv['from'] or { '' }
	if !emaillist.valid_email(from) {
		return error('the SES settings need a from address that looks like an email address')
	}
	reply_to := kv['reply_to'] or { '' }
	if reply_to != '' && !emaillist.valid_email(reply_to) {
		return error('reply_to is not an email address')
	}
	return SesConfig{
		region:     region
		access_key: key
		secret_key: secret
		from_addr:  from
		from_name:  (kv['from_name'] or { '' }).replace('"', '').replace('<', '').replace('>', '')
		config_set: kv['configuration_set'] or { '' }
		reply_to:   reply_to
	}
}

fn load_ses_config(path string) !SesConfig {
	text := os.read_file(path) or { return error('cannot read the SES settings at ${path}') }
	return parse_ses_config(text)
}

struct EmailMsg {
pub:
	to      string
	subject string
	text    string
}

// A subject is one line: any line break is turned into a space, and it is cut at a length no mail client minds.
fn one_line_subject(s string) string {
	t := s.replace('\r', ' ').replace('\n', ' ').trim_space()
	r := t.runes()
	return if r.len > 200 { r[..200].string() } else { t }
}

// A JSON string literal (RFC 8259): quotes, backslashes and control characters escaped, everything else as it is. The daemon avoids x.json2 (it crashed
// on FreeBSD, see minijson.v), so this and minijson's reader are all the JSON there is. Bytes that are not valid UTF-8 (a garbled radio message) are
// turned into '?' so the result is always valid JSON.
fn json_str(v string) string {
	s := if utf8.validate_str(v) {
		v
	} else {
		v.bytes().map(if it < 128 { it } else { u8(`?`) }).bytestr()
	}
	mut out := []u8{cap: s.len + 2}
	out << `"`
	for c in s.bytes() {
		match c {
			`"` {
				out << `\\`
				out << `"`
			}
			`\\` {
				out << `\\`
				out << `\\`
			}
			`\n` {
				out << `\\`
				out << `n`
			}
			`\r` {
				out << `\\`
				out << `r`
			}
			`\t` {
				out << `\\`
				out << `t`
			}
			else {
				if c < 0x20 {
					out << '\\u00'.bytes()
					out << '0123456789abcdef'[c >> 4]
					out << '0123456789abcdef'[c & 15]
				} else {
					out << c
				}
			}
		}
	}
	out << `"`
	return out.bytestr()
}

struct SesRequest {
pub:
	url     string
	headers map[string]string
	body    string
}

// The signed request that sends one message. `now` is epoch seconds; nothing here reads the clock or the network.
fn ses_request(cfg SesConfig, msg EmailMsg, now i64) SesRequest {
	host := 'email.${cfg.region}.amazonaws.com'
	from := if cfg.from_name != '' { '${cfg.from_name} <${cfg.from_addr}>' } else { cfg.from_addr }
	mut b := '{"FromEmailAddress":${json_str(from)},"Destination":{"ToAddresses":[${json_str(msg.to)}]},'
	if cfg.reply_to != '' {
		b += '"ReplyToAddresses":[${json_str(cfg.reply_to)}],'
	}
	if cfg.config_set != '' {
		b += '"ConfigurationSetName":${json_str(cfg.config_set)},'
	}
	b += '"Content":{"Simple":{"Subject":{"Data":${json_str(one_line_subject(msg.subject))},"Charset":"UTF-8"},"Body":{"Text":{"Data":${json_str(msg.text)},"Charset":"UTF-8"}}}}}'
	date := amz_date_of(now)
	signed := {
		'content-type': 'application/json'
		'host':         host
		'x-amz-date':   date
	}
	auth := sign_v4(AwsCreds{ access_key: cfg.access_key, secret_key: cfg.secret_key }, SignInput{
		method:   'POST'
		path:     '/v2/email/outbound-emails'
		headers:  signed
		body:     b
		region:   cfg.region
		service:  'ses'
		amz_date: date
	})
	return SesRequest{
		url:     'https://${host}/v2/email/outbound-emails'
		headers: {
			'Content-Type':  'application/json'
			'X-Amz-Date':    date
			'Authorization': auth
		}
		body:    b
	}
}

// ---- what an answer means ----

enum SendOutcome {
	sent     // delivered to SES
	rejected // SES will never take this message for this recipient: do not retry it
	retry    // not now (busy, network): try this message again later
	halt     // nothing can be sent until the sysop fixes the setup (credentials, unverified sender, paused account): stop and keep every message queued
}

struct SendResult {
pub:
	outcome    SendOutcome
	message_id string
	error      string
}

fn reply_field(body string, name string) string {
	parsed := parse_json(body) or { return '' }
	return parsed.str_of(name)
}

fn classify_ses_reply(cfg SesConfig, status int, body string) SendResult {
	if status == 200 {
		return SendResult{
			outcome:    .sent
			message_id: reply_field(body, 'MessageId')
		}
	}
	kind := reply_field(body, '__type').all_after('#')
	msg := (reply_field(body, 'message') + reply_field(body, 'Message')).trim_space()
	say := if msg != '' { msg } else { 'SES answered ${status}' }
	if status == 0 {
		return SendResult{
			outcome: .retry
			error:   'no answer from SES'
		}
	}
	if status == 429 || status >= 500 || kind in ['TooManyRequestsException', 'ThrottlingException',
		'LimitExceededException'] {
		return SendResult{
			outcome: .retry
			error:   say
		}
	}
	// the sender or the account is the problem, whoever the message is for
	sender_domain := cfg.from_addr.all_after('@').to_lower()
	if status in [401, 403] || kind in ['AccountSuspendedException', 'SendingPausedException',
		'MailFromDomainNotVerifiedException', 'NotFoundException'] {
		return SendResult{
			outcome: .halt
			error:   say
		}
	}
	if kind == 'MessageRejected' && (say.to_lower().contains(cfg.from_addr.to_lower()) || say.to_lower().contains(sender_domain)) {
		return SendResult{
			outcome: .halt
			error:   say
		}
	}
	return SendResult{
		outcome: .rejected
		error:   say
	}
}

// ---- the network, behind an interface ----

struct HttpReply {
pub:
	status int // 0 = there was no answer
	body   string
}

interface HttpSender {
mut:
	post(url string, headers map[string]string, body string) HttpReply
}

// Writes a file only its owner can read before the content goes in (the authorization header and the message are not for other users).
fn secret_file(path string, content string) ! {
	os.write_file(path, '')!
	os.chmod(path, 0o600)!
	os.write_file(path, content)!
}

struct CurlSender {
mut:
	n int
}

fn (mut c CurlSender) post(url string, headers map[string]string, body string) HttpReply {
	c.n++
	base := os.join_path(os.temp_dir(), 'meshbbs-ses-${os.getpid()}-${c.n}')
	hdr, bod, out := base + '.h', base + '.b', base + '.o'
	defer {
		for f in [hdr, bod, out] {
			os.rm(f) or {}
		}
	}
	mut lines := ''
	for k, v in headers {
		lines += '${k}: ${v}\n'
	}
	secret_file(hdr, lines) or { return HttpReply{} }
	secret_file(bod, body) or { return HttpReply{} }
	res := os.exec(['curl', '-s', '-m', '30', '-o', out, '-w', '%{http_code}', '-X', 'POST', '-H',
		'@${hdr}', '--data-binary', '@${bod}', url])
	if res.exit_code != 0 {
		return HttpReply{}
	}
	return HttpReply{
		status: res.output.trim_space().int()
		body:   os.read_file(out) or { '' }
	}
}

// Mailer sends one message at a time and says what happened; the queue (emailworker.v) decides what to do about it.
struct Mailer {
pub:
	cfg SesConfig
mut:
	sender HttpSender
}

fn (mut m Mailer) send(msg EmailMsg, now i64) SendResult {
	req := ses_request(m.cfg, msg, now)
	reply := m.sender.post(req.url, req.headers, req.body)
	return classify_ses_reply(m.cfg, reply.status, reply.body)
}
