module main

import emaillist

// A bucket held in memory that can fail on demand.
struct FakeBucket {
mut:
	objects     map[string]string
	order       []string
	deleted     []string
	gets        []string
	get_fails   map[string]int // key -> how many fetches fail before it works (a large number: always)
	delete_fail bool
	list_fail   bool
}

fn (mut b FakeBucket) put(key string, raw string) {
	b.objects[key] = raw
	b.order << key
}

fn (mut b FakeBucket) list(limit int) ![]ObjectInfo {
	if b.list_fail {
		return error('S3 answered 500')
	}
	mut out := []ObjectInfo{}
	for k in b.order {
		if k in b.objects && out.len < limit {
			out << ObjectInfo{
				key:  k
				size: b.objects[k].len
			}
		}
	}
	return out
}

fn (mut b FakeBucket) get(key string) !string {
	b.gets << key
	if (b.get_fails[key] or { 0 }) > 0 {
		b.get_fails[key]--
		return error('S3 answered 500')
	}
	return b.objects[key] or { return error('S3 answered 404') }
}

fn (mut b FakeBucket) delete(key string) ! {
	if b.delete_fail {
		return error('S3 answered 403')
	}
	b.objects.delete(key)
	b.deleted << key
}

// A place for the worker's log lines: held by reference, so a closure that is handed it can add to it.
struct LogRecorder {
mut:
	lines []string
}

fn (mut l LogRecorder) add(s string) {
	l.lines << s
}

fn mail_settings() InboundSettings {
	return InboundSettings{
		address:      'meshbbs@xerokuhl.com'
		group:        'mesh'
		tag:          '[mesh]'
		list_name:    'Buffalo Mesh'
		bucket:       'b'
		prefix:       'inbound/'
		max_bytes:    100000
		per_sender:   3
		posts_day:    20
		require_scan: true
		require_auth: true
	}
}

fn message(from string, subject string, body string, extra string) string {
	name := from.all_before('@')
	return 'Return-Path: <${from}>\nX-SES-Spam-Verdict: PASS\nX-SES-Virus-Verdict: PASS\nAuthentication-Results: amazonses.com; spf=pass client-ip=1.2.3.4; envelope-from=${from}; dkim=pass header.i=@${from.all_after('@')}; dmarc=pass header.from=${from.all_after('@')};\nFrom: ${name.capitalize()} <${from}>\nTo: meshbbs@xerokuhl.com\nSubject: ${subject}\n${extra}Content-Type: text/plain; charset=utf-8\n\n${body}\n'
}

struct Rig {
mut:
	w InboundWorker
	b &FakeBucket
	s Store
}

fn rig() Rig {
	mut st := new_store('sqlite::memory:') or { panic(err) }
	st.migrate() or {}
	st.ensure_email_group('mesh', '', 1) or { panic(err) }
	for who in ['ada@example.com', 'bob@example.com', 'carol@example.org'] {
		st.add_email_member('mesh', who, '', '', 1) or { panic(err) }
	}
	mut bucket := &FakeBucket{}
	return Rig{
		w: InboundWorker{
			store:    st
			objects:  bucket
			settings: mail_settings()
			contact:  'sysop@example.com'
		}
		b: bucket
		s: st
	}
}

fn queued_to(mut r Rig) []string {
	return r.s.due_emails(i64(9999999999), 50).map(it.to_addr)
}

// ---- a post ----

fn test_a_post_goes_to_everyone_on_the_list_except_the_sender() {
	mut r := rig()
	r.b.put('inbound/m1', message('dan@example.net', 'Net tonight', 'Net at 7 on the usual channel.', ''))
	r.s.add_email_member('mesh', 'ada@example.com', '', '', 1) or {}
	assert r.w.tick(1000) == true
	assert queued_to(mut r) == ['ada@example.com', 'bob@example.com', 'carol@example.org']
	q := r.s.due_emails(i64(9999999999), 1)[0]
	assert q.subject == '[mesh] Net tonight' && q.list_post == true && q.from_name == 'Dan' && q.group_name == 'mesh'
	assert q.body.starts_with('Net at 7 on the usual channel.\n\n--\nPosted to the Buffalo Mesh list by Dan <dan@example.net>.')
	assert r.b.deleted == ['inbound/m1'] && 'inbound/m1' !in r.b.objects
}

fn test_the_post_is_recorded_with_who_what_and_how_many() {
	mut r := rig()
	r.b.put('inbound/m1', message('dan@example.net', 'Net tonight', 'Net at 7.', ''))
	r.w.tick(1000)
	rec := r.s.recent_inbound(5)[0]
	assert rec.s3_key == 'inbound/m1' && rec.from_addr == 'dan@example.net' && rec.subject == 'Net tonight'
	assert rec.status == emaillist.inbound_posted && rec.recipients == 3 && rec.reason == '' && rec.received == 1000
}

fn test_a_member_who_posts_does_not_get_their_own_post_back() {
	mut r := rig()
	r.b.put('inbound/m1', message('ada@example.com', 'Hello all', 'Hi.', ''))
	r.w.tick(1000)
	assert queued_to(mut r) == ['bob@example.com', 'carol@example.org']
	assert r.s.recent_inbound(1)[0].recipients == 2
}

fn test_people_who_have_unsubscribed_or_been_refused_get_nothing() {
	mut r := rig()
	r.s.set_email_member_status('mesh', 'bob@example.com', emaillist.member_unsubscribed, '') or { panic(err) }
	r.s.set_email_member_status('mesh', 'carol@example.org', emaillist.member_rejected, 'not verified') or { panic(err) }
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	r.w.tick(1000)
	assert queued_to(mut r) == ['ada@example.com']
}

// ---- turned away ----

fn test_each_kind_of_turned_away_message_is_recorded_with_its_reason_and_nothing_is_sent() {
	mut r := rig()
	r.b.put('inbound/spam', message('dan@example.net', 's', 't', '').replace('X-SES-Spam-Verdict: PASS', 'X-SES-Spam-Verdict: FAIL'))
	r.b.put('inbound/auto', message('erin@example.net', 'Out of office', 't', 'Auto-Submitted: auto-replied\n'))
	r.b.put('inbound/forged', message('fay@example.net', 's', 't', '').replace('dmarc=pass', 'dmarc=fail'))
	r.b.put('inbound/garbage', 'this is not an email at all')
	r.w.tick(1000)
	assert queued_to(mut r).len == 0
	got := r.s.recent_inbound(10)
	assert got.len == 4 && got.all(it.status == emaillist.inbound_rejected)
	reasons := got.map(it.reason)
	assert reasons.any(it == 'flagged as spam') && reasons.any(it.contains('Auto-Submitted')) && reasons.any(it.contains('DMARC fail'))
	assert reasons.any(it == 'no usable sender address')
	assert r.b.deleted.len == 4 && r.b.objects.len == 0
}

fn test_a_blocked_sender_is_turned_away_and_a_blocked_domain_too() {
	mut r := rig()
	r.s.add_email_block('dan@example.net', '', 1) or { panic(err) }
	r.s.add_email_block('@spammy.example', '', 1) or { panic(err) }
	r.b.put('inbound/m1', message('dan@example.net', 'x', 't', ''))
	r.b.put('inbound/m2', message('anyone@spammy.example', 'x', 't', ''))
	r.b.put('inbound/m3', message('erin@fine.example', 'x', 't', ''))
	r.w.tick(1000)
	statuses := r.s.recent_inbound(10).map('${it.from_addr}=${it.status}')
	assert 'dan@example.net=rejected' in statuses && 'anyone@spammy.example=rejected' in statuses && 'erin@fine.example=posted' in statuses
}

fn test_pausing_turns_posts_away_but_not_stop_requests() {
	mut r := rig()
	r.s.set_email_setting(emaillist.setting_inbound_paused, '1') or { panic(err) }
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	r.b.put('inbound/m2', message('ada@example.com', 'x', 'STOP', ''))
	r.w.tick(1000)
	by := r.s.recent_inbound(10)
	assert by.filter(it.from_addr == 'dan@example.net')[0].reason == 'posting by email is paused'
	assert by.filter(it.from_addr == 'ada@example.com')[0].status == emaillist.inbound_stopped
}

fn test_a_sender_is_limited_per_day_and_the_limit_lifts_after_a_day() {
	mut r := rig()
	for i in 1 .. 5 {
		r.b.put('inbound/m${i}', message('dan@example.net', 'post ${i}', 'text ${i}', ''))
	}
	r.w.tick(1000)
	recs := r.s.recent_inbound(10)
	assert recs.filter(it.status == emaillist.inbound_posted).len == 3
	assert recs.filter(it.status == emaillist.inbound_rejected)[0].reason.contains('too many posts from this sender')
	r.b.put('inbound/later', message('dan@example.net', 'next day', 'text', ''))
	r.w.tick(1000 + 86400 + 61)
	assert r.s.recent_inbound(1)[0].status == emaillist.inbound_posted
}

fn test_the_whole_lists_daily_limit_follows_what_ses_can_send() {
	mut r := rig()
	r.w.daily_cap = 6 // 3 members, so only 2 posts a day can be delivered
	for i, who in ['dan@example.net', 'erin@example.net', 'fay@example.net'] {
		r.b.put('inbound/m${i}', message(who, 'x', 'text', ''))
	}
	r.w.tick(1000)
	recs := r.s.recent_inbound(10)
	// 6 emails a day and 3 people on the list: two posts fit, the third is turned away
	assert recs.filter(it.status == emaillist.inbound_posted).len == 2
	assert recs.filter(it.status == emaillist.inbound_rejected)[0].reason.contains('at its limit for today (2 posts)')
}

fn test_a_message_too_big_is_never_fetched() {
	mut r := rig()
	r.b.put('inbound/big', 'x'.repeat(100001))
	r.w.tick(1000)
	assert r.b.gets.len == 0 && r.b.deleted == ['inbound/big']
	assert r.s.recent_inbound(1)[0].reason.contains('too large')
}

// ---- STOP ----

fn test_a_member_who_writes_stop_is_taken_off_and_told() {
	mut r := rig()
	r.b.put('inbound/m1', message('bob@example.com', 'Re: [mesh] Net tonight', 'STOP', ''))
	r.w.tick(1000)
	assert (r.s.get_email_member('mesh', 'bob@example.com') or { panic('gone') }).status == emaillist.member_unsubscribed
	conf := r.s.due_emails(i64(9999999999), 5)
	assert conf.len == 1 && conf[0].to_addr == 'bob@example.com' && conf[0].subject == 'You are off the Buffalo Mesh list'
	assert conf[0].list_post == false && conf[0].body.contains('write to sysop@example.com')
	assert r.s.recent_inbound(1)[0].status == emaillist.inbound_stopped
}

fn test_stop_from_someone_not_on_the_list_changes_nothing() {
	mut r := rig()
	r.b.put('inbound/m1', message('zed@example.net', 'x', 'STOP', ''))
	r.w.tick(1000)
	assert queued_to(mut r).len == 0
	assert r.s.recent_inbound(1)[0].reason == 'asked to stop, but is not on the list'
}

fn test_stop_twice_sends_one_confirmation() {
	mut r := rig()
	r.b.put('inbound/m1', message('bob@example.com', 'x', 'STOP', ''))
	r.b.put('inbound/m2', message('bob@example.com', 'x', 'unsubscribe', ''))
	r.w.tick(1000)
	assert queued_to(mut r) == ['bob@example.com']
}

// ---- handled once, and when things fail ----

fn test_a_message_already_recorded_is_deleted_and_not_sent_again() {
	mut r := rig()
	r.s.inbound_begin('inbound/m1', 500) or { panic(err) }
	r.s.inbound_finish('inbound/m1', '', 'dan@example.net', '', 's', emaillist.inbound_posted, '', 3) or { panic(err) }
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	r.w.tick(1000)
	assert queued_to(mut r).len == 0 && r.b.gets.len == 0 && r.b.deleted == ['inbound/m1']
}

fn test_if_the_delete_fails_the_message_is_not_handled_twice() {
	mut r := rig()
	r.b.delete_fail = true
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	r.w.tick(1000)
	first := queued_to(mut r).len
	r.w.tick(1000 + 61)
	assert first == 3 && queued_to(mut r).len == 3
	r.b.delete_fail = false
	r.w.tick(1000 + 122)
	assert r.b.deleted == ['inbound/m1'] && queued_to(mut r).len == 3
}

fn test_a_fetch_that_fails_is_tried_again_and_given_up_on_after_five() {
	mut r := rig()
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	r.b.get_fails['inbound/m1'] = 2
	r.w.tick(1000)
	assert r.s.recent_inbound(5).len == 0 && r.b.objects.len == 1
	r.w.tick(1061)
	r.w.tick(1122) // the third try works
	assert r.s.recent_inbound(1)[0].status == emaillist.inbound_posted
	r.b.put('inbound/m2', 'x')
	r.b.get_fails['inbound/m2'] = 99
	mut t := i64(2000)
	for _ in 0 .. 5 {
		r.w.tick(t)
		t += 61
	}
	rec := r.s.recent_inbound(1)[0]
	assert rec.s3_key == 'inbound/m2' && rec.status == emaillist.inbound_failed && rec.reason.contains('could not be fetched')
	assert 'inbound/m2' !in r.b.objects
}

fn test_the_bucket_is_looked_at_once_a_minute() {
	mut r := rig()
	assert r.w.tick(1000) == true
	assert r.w.tick(1030) == false
	assert r.w.tick(1060) == true
}

fn test_if_the_bucket_cannot_be_listed_nothing_breaks_and_it_is_logged() {
	mut r := rig()
	r.b.list_fail = true
	rec := &LogRecorder{}
	r.w.log = fn [rec] (s string) {
		rec.add(s)
	}
	assert r.w.tick(1000) == true
	assert rec.lines.len == 1 && rec.lines[0].contains('could not look in the bucket')
}

fn test_if_the_group_is_missing_the_mail_stays_in_the_bucket() {
	mut r := rig()
	r.w.settings = InboundSettings{
		...r.w.settings
		group: 'gone'
	}
	r.b.put('inbound/m1', message('dan@example.net', 'x', 'text', ''))
	rec := &LogRecorder{}
	r.w.log = fn [rec] (s string) {
		rec.add(s)
	}
	r.w.tick(1000)
	assert r.b.objects.len == 1 && r.b.deleted.len == 0 && r.s.recent_inbound(5).len == 0
	assert rec.lines[0].contains('no email group called gone')
}

fn test_the_web_page_is_told_where_it_listens_when_it_last_looked_and_what_went_wrong() {
	mut r := rig()
	r.b.list_fail = true
	r.w.tick(1000)
	assert r.s.get_email_setting(emaillist.setting_inbound_address) == 'meshbbs@xerokuhl.com'
	assert r.s.get_email_setting(emaillist.setting_inbound_group) == 'mesh'
	assert r.s.get_email_setting(emaillist.setting_inbound_poll) == '1000'
	assert r.s.get_email_setting(emaillist.setting_inbound_error) == 'could not look in the bucket: S3 answered 500'
	r.b.list_fail = false
	r.w.tick(1061)
	assert r.s.get_email_setting(emaillist.setting_inbound_poll) == '1061'
	assert r.s.get_email_setting(emaillist.setting_inbound_error) == ''
}

fn test_a_missing_group_is_shown_as_the_problem() {
	mut r := rig()
	r.w.settings = InboundSettings{
		...r.w.settings
		group: 'gone'
	}
	r.w.tick(1000)
	assert r.s.get_email_setting(emaillist.setting_inbound_error).contains('no email group called gone')
}

fn test_an_empty_bucket_does_nothing() {
	mut r := rig()
	assert r.w.tick(1000) == true
	assert r.s.recent_inbound(5).len == 0 && queued_to(mut r).len == 0
}

fn test_an_html_only_post_with_an_attachment_is_passed_on_as_text_with_a_note() {
	mut r := rig()
	raw := 'X-SES-Spam-Verdict: PASS\nX-SES-Virus-Verdict: PASS\nAuthentication-Results: amazonses.com; dkim=pass header.i=@example.net; dmarc=pass header.from=example.net;\nFrom: Dan <dan@example.net>\nSubject: pic\nContent-Type: multipart/mixed; boundary="B"\n\n--B\nContent-Type: text/html\n\n<p>Look at <b>this</b></p>\n--B\nContent-Type: image/jpeg\nContent-Disposition: attachment\n\nxx\n--B--\n'
	r.b.put('inbound/m1', raw)
	r.w.tick(1000)
	q := r.s.due_emails(i64(9999999999), 1)[0]
	assert q.body.starts_with('Look at this') && q.body.contains('1 attachment was left out') && q.body.contains('was HTML')
}
