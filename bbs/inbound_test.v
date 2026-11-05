module main

fn settings() InboundSettings {
	return InboundSettings{
		address:      'meshbbs@xerokuhl.com'
		group:        'mesh'
		tag:          '[mesh]'
		list_name:    'Buffalo Mesh'
		bucket:       'b'
		prefix:       'inbound/'
		max_bytes:    1000000
		per_sender:   3
		posts_day:    20
		require_scan: true
		require_auth: true
	}
}

// A message as SES stores it: clean scans, SPF/DKIM/DMARC all passed for example.com. `extra` is more header lines.
fn good_raw(extra string, body string) string {
	return 'Return-Path: <ada@example.com>\nReceived: from mail.example.com\nX-SES-Spam-Verdict: PASS\nX-SES-Virus-Verdict: PASS\nAuthentication-Results: amazonses.com; spf=pass (spfCheck: domain of example.com designates 1.2.3.4 as permitted sender) client-ip=1.2.3.4; envelope-from=ada@example.com; dkim=pass header.i=@example.com; dmarc=pass header.from=example.com;\nFrom: Ada Lovelace <ada@example.com>\nTo: meshbbs@xerokuhl.com\nSubject: Net tonight\n${extra}Content-Type: text/plain; charset=utf-8\n\n${body}'
}

fn facts_for(raw string) InboundFacts {
	return InboundFacts{
		mail:      parse_mail(raw)
		raw_size:  raw.len
		members:   5
		daily_cap: 150
	}
}

fn verdict(raw string) InboundDecision {
	return decide(settings(), facts_for(raw))
}

fn test_a_clean_message_from_a_person_is_passed_on() {
	d := verdict(good_raw('', 'Net at 7 tonight.'))
	assert d.kind == .post && d.reason == ''
}

// ---- automatic and bulk mail ----

fn test_each_kind_of_automatic_mail_is_turned_away() {
	cases := {
		'X-Loop: meshbbs@xerokuhl.com\n':             'coming back'
		'Auto-Submitted: auto-replied\n':             'Auto-Submitted'
		'Auto-Submitted: auto-generated\n':           'Auto-Submitted'
		'Precedence: bulk\n':                         'Precedence'
		'Precedence: list\n':                         'Precedence'
		'Precedence: junk\n':                         'Precedence'
		'X-Auto-Response-Suppress: All\n':            'X-Auto-Response-Suppress'
		'List-Id: <news.example.com>\n':              'another mailing list'
		'List-Unsubscribe: <mailto:u@example.com>\n': 'another mailing list'
	}
	for header, want in cases {
		d := verdict(good_raw(header, 'text'))
		assert d.kind == .reject && d.reason.contains(want), '${header} -> ${d.reason}'
	}
}

fn test_a_person_who_marks_mail_as_not_automatic_is_still_a_person() {
	assert verdict(good_raw('Auto-Submitted: no\n', 'text')).kind == .post
	assert verdict(good_raw('Precedence: normal\n', 'text')).kind == .post
}

fn test_bounces_and_delivery_reports_are_turned_away() {
	assert verdict(good_raw('', 'text').replace('Return-Path: <ada@example.com>', 'Return-Path: <>')).reason.contains('bounce')
	assert verdict(good_raw('', 'text').replace('Content-Type: text/plain; charset=utf-8', 'Content-Type: multipart/report; report-type=delivery-status; boundary=x')).reason.contains('delivery report')
	for local in ['mailer-daemon', 'postmaster', 'noreply', 'no-reply', 'donotreply', 'noreply-billing'] {
		d := verdict(good_raw('', 'text').replace('Ada Lovelace <ada@example.com>', '${local}@example.com'))
		assert d.kind == .reject && d.reason.contains('no-reply'), local
	}
}

fn test_mail_from_the_list_address_itself_is_turned_away() {
	d := verdict(good_raw('', 'text').replace('Ada Lovelace <ada@example.com>', 'Buffalo Mesh <MeshBBS@Xerokuhl.com>'))
	assert d.kind == .reject && d.reason.contains('own address')
}

// ---- the scans and who it is from ----

fn test_the_spam_and_virus_verdicts() {
	assert verdict(good_raw('', 't').replace('X-SES-Spam-Verdict: PASS', 'X-SES-Spam-Verdict: FAIL')).reason == 'flagged as spam'
	assert verdict(good_raw('', 't').replace('X-SES-Virus-Verdict: PASS', 'X-SES-Virus-Verdict: FAIL')).reason == 'flagged as a virus'
	assert verdict(good_raw('', 't').replace('X-SES-Spam-Verdict: PASS', 'X-SES-Spam-Verdict: GRAY')).reason.contains('not cleared by the spam scan (GRAY)')
	assert verdict(good_raw('', 't').replace('X-SES-Virus-Verdict: PASS', 'X-SES-Virus-Verdict: PROCESSING_FAILED')).reason.contains('virus scan (PROCESSING_FAILED)')
}

fn test_a_message_with_no_verdict_is_turned_away_unless_scans_are_not_required() {
	no_verdict := good_raw('', 't').replace('X-SES-Spam-Verdict: PASS\n', '')
	assert verdict(no_verdict).reason.contains('no verdict')
	mut s := settings()
	s = InboundSettings{
		...s
		require_scan: false
	}
	assert decide(s, facts_for(no_verdict)).kind == .post
	// but a FAIL is never let through
	assert decide(s, facts_for(good_raw('', 't').replace('X-SES-Spam-Verdict: PASS', 'X-SES-Spam-Verdict: FAIL'))).kind == .reject
}

fn test_forged_and_unverified_senders_are_turned_away() {
	forged := good_raw('', 't').replace('dmarc=pass header.from=example.com', 'dmarc=fail header.from=example.com')
	assert verdict(forged).reason.contains('DMARC fail')
	// SPF passed, but for somebody else's domain: not the From domain
	other := good_raw('', 't').replace('example.com designates', 'evil.org designates').replace('envelope-from=ada@example.com', 'envelope-from=x@evil.org').replace('dkim=pass header.i=@example.com', 'dkim=none').replace('dmarc=pass header.from=example.com', 'dmarc=none')
	assert verdict(other).reason.contains('could not be verified')
	nothing := good_raw('', 't').replace('Authentication-Results:', 'X-Other:')
	assert verdict(nothing).reason.contains('could not be verified')
}

fn test_dkim_or_spf_for_the_from_domain_is_enough_when_dmarc_says_nothing() {
	no_dmarc := good_raw('', 't').replace('dmarc=pass header.from=example.com', 'dmarc=none')
	assert verdict(no_dmarc).kind == .post
	only_spf := good_raw('', 't').replace('dkim=pass header.i=@example.com; ', '').replace('dmarc=pass header.from=example.com', 'dmarc=none')
	assert verdict(only_spf).kind == .post
}

fn test_a_domain_that_only_ends_the_same_way_is_not_the_from_domain() {
	// the findings mention evilexample.com, and the message claims to be from example.com
	raw := good_raw('', 't').replace('example.com designates', 'evilexample.com designates').replace('envelope-from=ada@example.com', 'envelope-from=x@evilexample.com').replace('dkim=pass header.i=@example.com', 'dkim=pass header.i=@evilexample.com').replace('dmarc=pass header.from=example.com', 'dmarc=none')
	assert verdict(raw).reason.contains('could not be verified')
	assert has_domain('x@mail.example.com', 'example.com') && has_domain('header.i=@example.com;', 'example.com')
	assert !has_domain('x@evilexample.com', 'example.com') && !has_domain('example.com.evil.org', 'example.com') && !has_domain('', 'example.com')
}

fn test_with_authentication_not_required_an_unverified_sender_gets_through() {
	s := InboundSettings{
		...settings()
		require_auth: false
	}
	nothing := good_raw('', 't').replace('Authentication-Results:', 'X-Other:')
	assert decide(s, facts_for(nothing)).kind == .post
}

// ---- who and how much ----

fn test_a_blocked_sender_is_turned_away() {
	mut f := facts_for(good_raw('', 'text'))
	f = InboundFacts{
		...f
		blocked: true
	}
	assert decide(settings(), f).reason == 'the sender is blocked'
}

fn test_the_limits_per_sender_per_day_and_the_ses_quota() {
	raw := good_raw('', 'text')
	base := facts_for(raw)
	assert decide(settings(), InboundFacts{
		...base
		sender_posts_today: 2
	}).kind == .post
	assert decide(settings(), InboundFacts{
		...base
		sender_posts_today: 3
	}).reason.contains('too many posts from this sender')
	assert decide(settings(), InboundFacts{
		...base
		posts_today: 19
	}).kind == .post
	assert decide(settings(), InboundFacts{
		...base
		posts_today: 20
	}).reason.contains('at its limit for today (20 posts)')
	// 5 members and a cap of 150 emails a day is 30 posts, so the setting of 20 is what binds; with 20 members it is 7
	assert decide(settings(), InboundFacts{
		...base
		members:     20
		posts_today: 7
	}).reason.contains('(7 posts)')
	// a huge list still lets one post through a day
	assert decide(settings(), InboundFacts{
		...base
		members:   1000
		daily_cap: 150
	}).kind == .post
}

fn test_a_full_sending_queue_and_an_empty_list_stop_a_post() {
	base := facts_for(good_raw('', 'text'))
	assert decide(settings(), InboundFacts{
		...base
		queued: 301
	}).reason == 'the sending queue is full'
	assert decide(settings(), InboundFacts{
		...base
		queued: 300
	}).kind == .post
	assert decide(settings(), InboundFacts{
		...base
		members: 0
	}).reason == 'nobody is on the list'
}

fn test_pausing_stops_posts_but_not_requests_to_be_taken_off() {
	paused_post := InboundFacts{
		...facts_for(good_raw('', 'text'))
		paused: true
	}
	assert decide(settings(), paused_post).reason == 'posting by email is paused'
	paused_stop := InboundFacts{
		...facts_for(good_raw('', 'STOP'))
		paused: true
	}
	assert decide(settings(), paused_stop).kind == .stop
}

fn test_too_big_no_sender_and_no_text() {
	assert verdict(good_raw('', 'x'.repeat(1000001))).reason.contains('too large')
	assert verdict(good_raw('', 'text').replace('From: Ada Lovelace <ada@example.com>', 'From: nobody')).reason == 'no usable sender address'
	assert verdict(good_raw('', '   \n  ')).reason == 'no text in the message'
}

// ---- STOP ----

fn test_the_ways_people_ask_to_be_taken_off() {
	for body in ['STOP', 'stop', 'Stop.', 'unsubscribe', 'Unsubscribe me', 'please remove me!',
		'  remove  ', 'STOP\n\n> the original post\n> more', '\n\nUNSUBSCRIBE\n\n--\nAda'] {
		assert is_stop_request(parse_mail(good_raw('', body))), body
	}
}

fn test_a_stop_in_the_subject_with_nothing_else_counts() {
	m := parse_mail(good_raw('', '').replace('Subject: Net tonight', 'Subject: Re: STOP'))
	assert is_stop_request(m)
}

fn test_a_post_that_mentions_stopping_is_still_a_post() {
	for body in ['Please do not stop the net.', 'stop by the shop tonight',
		'Can someone unsubscribe me? I forgot how.', '> STOP\nI disagree', 'Hello\nSTOP'] {
		assert !is_stop_request(parse_mail(good_raw('', body))), body
	}
}

fn test_a_stop_is_a_stop_decision() {
	assert verdict(good_raw('', 'STOP')).kind == .stop
}

fn test_a_stop_from_an_unverified_sender_is_turned_away_not_obeyed() {
	forged := good_raw('', 'STOP').replace('dmarc=pass header.from=example.com', 'dmarc=fail header.from=example.com')
	assert verdict(forged).kind == .reject
}

// ---- what is sent on ----

fn test_the_subject_gets_the_tag_once() {
	assert tag_subject('[mesh]', 'Net tonight') == '[mesh] Net tonight'
	assert tag_subject('[mesh]', '[mesh] Net tonight') == '[mesh] Net tonight'
	assert tag_subject('[mesh]', '[MESH] again') == '[MESH] again'
	assert tag_subject('[mesh]', 'Re: [mesh] Net tonight') == 'Re: [mesh] Net tonight'
	assert tag_subject('[mesh]', 'Re: Net tonight') == '[mesh] Re: Net tonight'
	assert tag_subject('[mesh]', '') == '[mesh] (no subject)'
	assert tag_subject('', 'x') == 'x'
}

fn test_the_post_says_who_wrote_it_how_to_answer_and_how_to_stop() {
	m := parse_mail(good_raw('', 'Net at 7.'))
	b := compose_post_body(settings(), m)
	assert b.starts_with('Net at 7.\n\n--\nPosted to the Buffalo Mesh list by Ada Lovelace <ada@example.com>.')
	assert b.contains('Reply to this email to answer everyone') && b.contains('write to ada@example.com to answer only them')
	assert b.contains('reply with the one word STOP')
}

fn test_the_post_notes_what_was_left_out() {
	m := parse_mail('From: a@b.co\nSubject: x\nContent-Type: multipart/mixed; boundary="B"\n\n--B\nContent-Type: text/html\n\n<p>hello</p>\n--B\nContent-Type: image/png\nContent-Disposition: attachment\n\nxx\n--B--\n')
	b := compose_post_body(settings(), m)
	assert b.contains('1 attachment was left out') && b.contains('was HTML')
}

fn test_a_poster_with_no_name_is_called_by_the_part_before_the_at() {
	m := parse_mail('From: ada.l@example.com\nSubject: x\n\nhi')
	assert poster_name(m) == 'ada.l'
}

fn test_a_very_long_post_is_cut() {
	m := parse_mail(good_raw('', 'x'.repeat(9000)))
	b := compose_post_body(settings(), m)
	assert b.contains('[cut]') && b.len < 5800
}

// ---- turning the settings file into the list's settings ----

fn test_the_list_settings_come_from_the_ses_file_and_default_sensibly() {
	c := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\nfrom_name=Buffalo Mesh\nlist_address=MeshBBS@xerokuhl.com\ninbound_bucket=my-mail-bucket\ninbound_group=mesh\n') or {
		panic(err)
	}
	s := inbound_settings(c) or { panic('should be on') }
	assert s.address == 'meshbbs@xerokuhl.com' && s.group == 'mesh' && s.bucket == 'my-mail-bucket'
	assert s.prefix == 'inbound/' && s.tag == '[mesh]' && s.list_name == 'Buffalo Mesh'
	assert s.max_bytes == 1000000 && s.per_sender == 3 && s.posts_day == 20 && s.require_scan && s.require_auth
}

fn test_without_a_bucket_or_a_group_posting_by_email_is_off() {
	a := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\ninbound_group=mesh\n') or { panic(err) }
	assert inbound_settings(a) == none
	b := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\ninbound_bucket=my-mail-bucket\n') or { panic(err) }
	assert inbound_settings(b) == none
}

fn test_bad_list_settings_are_refused_in_words() {
	base := 'access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\n'
	for line, want in {
		'inbound_bucket=NOT A BUCKET\n':      'bucket'
		'inbound_bucket=ab\n':                'bucket'
		'inbound_prefix=/leading\n':          'inbound_prefix'
		'inbound_prefix=no-trailing-slash\n': 'inbound_prefix'
		'inbound_prefix=a b/\n':              'inbound_prefix'
		'inbound_group=bad group\n':          'inbound_group'
		'list_address=nope\n':                'list_address'
		'inbound_max_bytes=12\n':             'inbound_max_bytes'
		'inbound_per_sender_day=0\n':         'inbound_per_sender_day'
		'inbound_posts_day=lots\n':           'inbound_posts_day'
	} {
		parse_ses_config(base + line) or {
			assert err.msg().contains(want), '${line} -> ${err.msg()}'
			continue
		}
		assert false, 'accepted: ${line}'
	}
}

fn test_the_scan_and_auth_requirements_can_be_switched_off_only_by_a_zero() {
	c := parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\ninbound_require_scan=0\ninbound_require_auth=false\n') or {
		panic(err)
	}
	assert !c.require_scan && c.require_auth // "false" is not 0: only an explicit 0 relaxes a safety check
}
