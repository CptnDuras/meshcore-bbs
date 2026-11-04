module main

// A sender that answers from a script and remembers what it was asked to send.
struct ScriptedSender {
mut:
	answers []SendResult
	sent    []string
}

fn (mut s ScriptedSender) send(msg EmailMsg, now i64) SendResult {
	s.sent << msg.to
	if s.answers.len == 0 {
		return SendResult{
			outcome:    .sent
			message_id: 'm-default'
		}
	}
	r := s.answers[0]
	s.answers = s.answers[1..].clone()
	return r
}

// A network that always says "sent", for the one test that runs the real Mailer.
struct StubHttp {
mut:
	calls []string
}

fn (mut s StubHttp) post(url string, headers map[string]string, body string) HttpReply {
	s.calls << url
	return HttpReply{
		status: 200
		body:   '{"MessageId":"x"}'
	}
}

fn worker_with(answers []SendResult) (EmailWorker, &ScriptedSender) {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	mut sender := &ScriptedSender{
		answers: answers
	}
	return EmailWorker{
		store:  store
		sender: sender
	}, sender
}

fn queue(mut w EmailWorker, to string, group string) {
	w.store.enqueue_email(to, 'Subject', 'Body', group, 1000) or { panic(err) }
}

fn test_a_message_is_sent_once_and_marked() {
	mut w, sender := worker_with([SendResult{ outcome: .sent, message_id: 'm-1' }])
	queue(mut w, 'ada@example.com', 'family')
	assert w.tick(1000) == true
	assert sender.sent == ['ada@example.com']
	assert w.store.count_emails(email_sent) == 1 && w.store.count_emails(email_queued) == 0
	assert w.tick(1001) == false
	assert sender.sent.len == 1
}

fn test_one_message_goes_each_tick() {
	mut w, sender := worker_with([])
	queue(mut w, 'a@example.com', 'g')
	queue(mut w, 'b@example.com', 'g')
	queue(mut w, 'c@example.com', 'g')
	w.tick(1000)
	assert sender.sent == ['a@example.com']
	w.tick(1001)
	w.tick(1002)
	assert sender.sent == ['a@example.com', 'b@example.com', 'c@example.com']
}

fn test_a_member_gets_a_last_sent_time() {
	mut w, _ := worker_with([])
	w.store.ensure_email_group('g', '', 1) or { panic(err) }
	w.store.add_email_member('g', 'ada@example.com', '', '', 1) or { panic(err) }
	queue(mut w, 'ada@example.com', 'g')
	w.tick(5000)
	m := w.store.get_email_member('g', 'ada@example.com') or { panic('gone') }
	assert m.last_sent == 5000
}

fn test_a_refused_address_fails_that_message_and_marks_the_member() {
	mut w, _ := worker_with([SendResult{ outcome: .rejected, error: 'Email address is not verified' }])
	w.store.ensure_email_group('g', '', 1) or { panic(err) }
	w.store.add_email_member('g', 'ada@example.com', '', '', 1) or { panic(err) }
	queue(mut w, 'ada@example.com', 'g')
	w.tick(1000)
	assert w.store.count_emails(email_failed) == 1
	m := w.store.get_email_member('g', 'ada@example.com') or { panic('gone') }
	assert m.status == member_rejected && m.last_error == 'Email address is not verified'
}

fn test_a_busy_service_is_retried_later_with_longer_waits_and_then_given_up() {
	mut w, sender := worker_with([SendResult{ outcome: .retry, error: 'busy' }].repeat(10))
	queue(mut w, 'ada@example.com', 'g')
	waits := [i64(60), 300, 1800, 7200, 21600]
	mut now := i64(1000)
	for wait in waits {
		assert w.tick(now) == true
		assert w.tick(now + wait - 1) == false // not yet
		now += wait
	}
	assert w.store.count_emails(email_queued) == 1
	assert w.tick(now) == true // the sixth try is the last
	assert w.store.count_emails(email_failed) == 1 && w.store.count_emails(email_queued) == 0
	assert sender.sent.len == 6
	f := w.store.recent_failed_emails(1)[0]
	assert f.last_error.contains('gave up after 6 tries') && f.last_error.contains('busy')
}

fn test_a_setup_problem_keeps_everything_queued_and_rests_the_worker() {
	mut w, sender := worker_with([SendResult{ outcome: .halt, error: 'sender not verified' }])
	queue(mut w, 'a@example.com', 'g')
	queue(mut w, 'b@example.com', 'g')
	assert w.tick(1000) == true
	assert w.last_halt == 'sender not verified'
	assert w.store.count_emails(email_queued) == 2 && w.store.count_emails(email_failed) == 0
	assert w.tick(1001) == false && w.tick(1000 + email_halt_rest - 1) == false
	assert sender.sent.len == 1
	assert w.tick(1000 + email_halt_rest) == true // after the rest it tries again (and now succeeds)
	assert w.store.count_emails(email_sent) == 1
}

fn test_the_daily_cap_holds_messages_back_and_releases_them_a_day_later() {
	mut w, sender := worker_with([])
	w.daily_cap = 2
	for a in ['a', 'b', 'c'] {
		queue(mut w, '${a}@example.com', 'g')
	}
	w.tick(1000)
	w.tick(1001)
	assert w.tick(1002) == false && w.capped == true
	assert sender.sent.len == 2 && w.store.count_emails(email_queued) == 1
	assert w.tick(1001 + 86400) == true && w.capped == false
	assert sender.sent.len == 3
}

fn test_an_address_that_got_into_the_queue_but_is_not_one_is_failed_without_asking_ses() {
	mut w, sender := worker_with([])
	queue(mut w, 'not an address', 'g')
	assert w.tick(1000) == true
	assert sender.sent.len == 0 && w.store.count_emails(email_failed) == 1
}

fn test_old_finished_mail_is_pruned_and_queued_mail_is_kept() {
	mut w, _ := worker_with([])
	queue(mut w, 'a@example.com', 'g')
	queue(mut w, 'b@example.com', 'g')
	w.tick(1000) // a is sent
	w.store.prune_emails(i64(99999)) or { panic(err) }
	assert w.store.count_emails(email_sent) == 0 && w.store.count_emails(email_queued) == 1
}

fn test_the_mailer_can_stand_in_for_the_sender() {
	// compile-time check that the real Mailer satisfies the worker's interface
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	mut fake := &StubHttp{}
	mut w := EmailWorker{
		store:  store
		sender: Mailer{
			cfg:    parse_ses_config('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\n') or { panic(err) }
			sender: fake
		}
	}
	w.store.enqueue_email('a@example.com', 's', 'b', 'g', 1) or { panic(err) }
	assert w.tick(1440938160) == true
	assert w.store.count_emails(email_sent) == 1
	assert fake.calls.len == 1
}
