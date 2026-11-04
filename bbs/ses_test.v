module main

const good_conf = 'region=us-west-2
access_key_id=AKIAEXAMPLE
secret_access_key=secretexample
from=mesh@xerokuhl.com
from_name=Buffalo Mesh
configuration_set=meshbbs
reply_to=sysop@xerokuhl.com
'

fn conf() SesConfig {
	return parse_ses_config(good_conf) or { panic(err) }
}

// the text at a path of object names in a decoded JSON document ('' if the path is not there)
fn jget(doc JVal, path []string) string {
	mut cur := doc
	for name in path {
		cur = cur.get(name)
	}
	return cur.s
}

// ---- the settings file ----

fn test_a_good_settings_file_is_read() {
	c := conf()
	assert c.region == 'us-west-2'
	assert c.access_key == 'AKIAEXAMPLE' && c.secret_key == 'secretexample'
	assert c.from_addr == 'mesh@xerokuhl.com' && c.from_name == 'Buffalo Mesh'
	assert c.config_set == 'meshbbs' && c.reply_to == 'sysop@xerokuhl.com'
}

fn test_comments_blank_lines_and_key_case_are_ignored() {
	c := parse_ses_config('# a comment\n\nACCESS_KEY_ID = AK\nSecret_Access_Key=SK\nFrom=a@b.co\n') or { panic(err) }
	assert c.access_key == 'AK' && c.secret_key == 'SK' && c.from_addr == 'a@b.co' && c.region == 'us-west-2'
}

fn test_a_missing_key_or_from_address_is_refused() {
	parse_ses_config('access_key_id=AK\nfrom=a@b.co\n') or {
		assert err.msg().contains('secret_access_key')
		return
	}
	assert false
}

fn test_a_from_address_that_is_not_an_address_is_refused() {
	parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=not an address\n') or {
		assert err.msg().contains('from address')
		return
	}
	assert false
}

fn test_a_region_that_is_not_a_region_is_refused_so_it_cannot_change_the_host() {
	parse_ses_config('region=evil.example.com/x\naccess_key_id=AK\nsecret_access_key=SK\nfrom=a@b.co\n') or {
		assert err.msg().contains('region')
		return
	}
	assert false
}

fn test_a_value_with_a_control_character_is_refused() {
	parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=a@b.co\nfrom_name=Mesh\x01\n') or {
		assert err.msg().contains('control character')
		return
	}
	assert false
}

fn test_quotes_and_angle_brackets_cannot_come_through_the_display_name() {
	c := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=a@b.co\nfrom_name=Eve" <evil@x.com>\n') or { panic(err) }
	assert !c.from_name.contains('"') && !c.from_name.contains('<') && !c.from_name.contains('>')
}

// ---- addresses ----

fn test_ordinary_addresses_pass() {
	for a in ['a@b.co', 'first.last+tag@sub.example.org', 'x_y-z@example-mail.com'] {
		assert valid_email(a), a
	}
}

fn test_addresses_that_are_not_addresses_or_that_carry_tricks_fail() {
	for a in ['', 'plain', 'a@b', '@b.co', 'a@@b.co', 'a b@c.co', 'a@b.co,c@d.co', '<a@b.co>',
		'"a"@b.co', 'a@b.co\nBcc: x@y.z', 'a@.co', 'a@b..co', 'a@b.co.', 'a(c)@b.co', 'a@b_c.co'] {
		assert !valid_email(a), a
	}
}

// ---- the request ----

fn test_the_request_goes_to_the_regions_ses_endpoint_and_is_signed() {
	req := ses_request(conf(), EmailMsg{ to: 'friend@example.com', subject: 'Hello', text: 'Body' }, 1440938160)
	assert req.url == 'https://email.us-west-2.amazonaws.com/v2/email/outbound-emails'
	assert req.headers['X-Amz-Date'] == '20150830T123600Z'
	auth := req.headers['Authorization']
	assert auth.starts_with('AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20150830/us-west-2/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=')
	assert auth.all_after('Signature=').len == 64
}

fn test_the_same_message_at_another_time_has_another_signature() {
	m := EmailMsg{ to: 'friend@example.com', subject: 'Hello', text: 'Body' }
	a := ses_request(conf(), m, 1440938160).headers['Authorization']
	assert ses_request(conf(), m, 1440938161).headers['Authorization'] != a
	assert ses_request(conf(), m, 1440938160).headers['Authorization'] == a
}

fn test_the_body_is_valid_json_with_the_recipient_sender_subject_and_text() {
	req := ses_request(conf(), EmailMsg{ to: 'friend@example.com', subject: 'Hello', text: 'Line one\nLine two' }, 0)
	doc := parse_json(req.body) or { panic('body is not json') }
	assert doc.str_of('FromEmailAddress') == 'Buffalo Mesh <mesh@xerokuhl.com>'
	assert doc.get('Destination').get('ToAddresses').arr.map(it.s) == ['friend@example.com']
	assert doc.get('ReplyToAddresses').arr.map(it.s) == ['sysop@xerokuhl.com']
	assert doc.str_of('ConfigurationSetName') == 'meshbbs'
	assert jget(doc, ['Content', 'Simple', 'Subject', 'Data']) == 'Hello'
	assert jget(doc, ['Content', 'Simple', 'Body', 'Text', 'Data']) == 'Line one\nLine two'
}

fn test_quotes_slashes_unicode_and_markup_in_the_message_stay_inside_their_strings() {
	text := 'He said "hi" \\ and <script>alert(1)</script> — café 日本語\ttab'
	req := ses_request(conf(), EmailMsg{ to: 'a@b.co', subject: 'Q"uote', text: text }, 0)
	doc := parse_json(req.body) or { panic('body is not json') }
	assert jget(doc, ['Content', 'Simple', 'Body', 'Text', 'Data']) == text
	assert jget(doc, ['Content', 'Simple', 'Subject', 'Data']) == 'Q"uote'
}

// ---- the JSON writer ----

fn test_json_strings_are_escaped_as_the_standard_says() {
	assert json_str('plain') == '"plain"'
	assert json_str('a"b') == '"a\\"b"'
	assert json_str('a\\b') == '"a\\\\b"'
	assert json_str('l1\nl2\r\tx') == '"l1\\nl2\\r\\tx"'
	assert json_str('\x01\x1f') == '"\\u0001\\u001f"'
	assert json_str('café 日本語 —') == '"café 日本語 —"'
	assert json_str('') == '""'
}

fn test_whatever_goes_in_comes_back_out_of_the_reader_unchanged() {
	for s in ['', 'a', '"', '\\', 'tab\there', 'nl\nnl', '\x00\x08\x0c', '</script>', "it's", 'a\\"b\\\\"c',
		'é日本語😀'] {
		got := parse_json('{"k":${json_str(s)}}') or { panic('not json for ${s.bytes()}') }
		assert got.str_of('k') == s, 'round trip of ${s.bytes()}'
	}
}

fn test_bytes_that_are_not_utf8_become_question_marks_so_the_json_stays_valid() {
	bad := 'ok\xff\xfe!'
	out := json_str(bad)
	assert out == '"ok??!"'
	assert (parse_json('{"k":${out}}') or { panic('not json') }).str_of('k') == 'ok??!'
}

fn test_a_subject_is_one_line_and_not_longer_than_200_characters() {
	assert one_line_subject('a\r\nBcc: x@y.z\nb') == 'a  Bcc: x@y.z b'
	assert one_line_subject('é'.repeat(300)).runes().len == 200
	req := ses_request(conf(), EmailMsg{ to: 'a@b.co', subject: 'x\r\nBcc: evil@x.com', text: 't' }, 0)
	assert !req.body.contains('\r') && !req.body.contains('\\r\\nBcc')
}

fn test_without_a_display_name_or_options_those_parts_are_left_out() {
	c := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=a@b.co\n') or { panic(err) }
	req := ses_request(c, EmailMsg{ to: 'x@y.zz', subject: 's', text: 't' }, 0)
	assert req.body.contains('"FromEmailAddress":"a@b.co"') && !req.body.contains('ReplyToAddresses') && !req.body.contains('ConfigurationSetName')
}

// ---- what an answer means ----

fn test_a_200_is_sent_and_carries_the_message_id() {
	r := classify_ses_reply(conf(), 200, '{"MessageId":"0100018abc-1234"}')
	assert r.outcome == .sent && r.message_id == '0100018abc-1234'
}

fn test_throttling_server_errors_and_no_answer_are_retried() {
	assert classify_ses_reply(conf(), 429, '{"__type":"TooManyRequestsException","message":"slow down"}').outcome == .retry
	assert classify_ses_reply(conf(), 503, '').outcome == .retry
	assert classify_ses_reply(conf(), 500, '{"message":"oops"}').outcome == .retry
	assert classify_ses_reply(conf(), 0, '').outcome == .retry
}

fn test_a_recipient_that_is_not_verified_is_rejected_for_that_message_only() {
	body := '{"__type":"MessageRejected","message":"Email address is not verified. The following identities failed the check in region US-WEST-2: friend@example.com"}'
	r := classify_ses_reply(conf(), 400, body)
	assert r.outcome == .rejected && r.error.contains('not verified')
}

fn test_an_unverified_sender_halts_the_queue_instead_of_failing_every_message() {
	body := '{"__type":"MessageRejected","message":"Email address is not verified. The following identities failed the check in region US-WEST-2: mesh@xerokuhl.com"}'
	assert classify_ses_reply(conf(), 400, body).outcome == .halt
	dom := '{"__type":"MessageRejected","message":"Email address is not verified. The following identities failed the check in region US-WEST-2: xerokuhl.com"}'
	assert classify_ses_reply(conf(), 400, dom).outcome == .halt
}

fn test_bad_credentials_a_paused_account_and_a_missing_identity_halt() {
	assert classify_ses_reply(conf(), 403, '{"__type":"InvalidSignatureException","message":"bad"}').outcome == .halt
	assert classify_ses_reply(conf(), 400, '{"__type":"SendingPausedException","message":"paused"}').outcome == .halt
	assert classify_ses_reply(conf(), 400, '{"__type":"AccountSuspendedException","message":"suspended"}').outcome == .halt
	assert classify_ses_reply(conf(), 404, '{"__type":"NotFoundException","message":"x"}').outcome == .halt
}

fn test_any_other_400_is_rejected_with_the_services_words() {
	r := classify_ses_reply(conf(), 400, '{"__type":"BadRequestException","message":"Invalid address"}')
	assert r.outcome == .rejected && r.error == 'Invalid address'
}

// ---- the mailer, with a fake network ----

struct FakeSender {
mut:
	calls   []string
	status  int
	reply   string
	headers []map[string]string
}

fn (mut f FakeSender) post(url string, headers map[string]string, body string) HttpReply {
	f.calls << url + ' ' + body
	f.headers << headers
	return HttpReply{
		status: f.status
		body:   f.reply
	}
}

fn test_the_mailer_signs_posts_and_reports() {
	mut fake := &FakeSender{
		status: 200
		reply:  '{"MessageId":"m-1"}'
	}
	mut m := Mailer{
		cfg:    conf()
		sender: fake
	}
	r := m.send(EmailMsg{ to: 'friend@example.com', subject: 'Hi', text: 'There' }, 1440938160)
	assert r.outcome == .sent && r.message_id == 'm-1'
	assert fake.calls.len == 1 && fake.calls[0].starts_with('https://email.us-west-2.amazonaws.com/v2/email/outbound-emails {')
	assert fake.headers[0]['Authorization'].starts_with('AWS4-HMAC-SHA256')
}

fn test_the_mailer_passes_a_refusal_through() {
	mut fake := &FakeSender{
		status: 400
		reply:  '{"__type":"MessageRejected","message":"Email address is not verified. The following identities failed the check in region US-WEST-2: friend@example.com"}'
	}
	mut m := Mailer{
		cfg:    conf()
		sender: fake
	}
	assert m.send(EmailMsg{ to: 'friend@example.com', subject: 'Hi', text: 'x' }, 0).outcome == .rejected
}
