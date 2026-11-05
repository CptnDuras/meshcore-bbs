module main

import os

// A sender that answers every message the same way and remembers the last one.
struct CliSender {
mut:
	answer SendResult
	last   EmailMsg
}

fn (mut c CliSender) send(msg EmailMsg, now i64) SendResult {
	c.last = msg
	return c.answer
}

fn cli_store() Store {
	mut s := new_store('sqlite::memory:') or { panic(err) }
	s.migrate() or {}
	return s
}

fn temp_list(name string, text string) string {
	path := os.join_path(os.temp_dir(), 'meshbbs-cli-${os.getpid()}-${name}')
	os.write_file(path, text) or { panic(err) }
	return path
}

fn run_cli(args []string, mut store Store, answer SendResult) (string, int, &CliSender) {
	mut sender := &CliSender{
		answer: answer
	}
	mut as_iface := EmailSender(sender)
	out, code := email_cli(args, mut store, mut as_iface, 1000)
	return out, code, sender
}

fn test_import_makes_the_group_and_adds_everyone_once() {
	mut st := cli_store()
	path := temp_list('a', '# family\nada@example.com Ada Lovelace\nbob@example.com\nADA@example.com dup\nnot a person\n')
	defer {
		os.rm(path) or {}
	}
	out, code, _ := run_cli(['import', 'Family', path], mut st, SendResult{})
	assert code == 0
	assert out.contains('family (new group): 2 added, 0 already there') && out.contains('1 line skipped') && out.contains('  not a person')
	ms := st.list_email_members('family')
	assert ms.map(it.email) == ['ada@example.com', 'bob@example.com']
	assert ms[0].name == 'Ada Lovelace' && ms[0].status == member_active
	assert ms[0].note.starts_with('imported from meshbbs-cli-')
}

fn test_importing_again_changes_nothing_and_never_revives_an_unsubscribed_person() {
	mut st := cli_store()
	path := temp_list('b', 'ada@example.com\nbob@example.com\n')
	defer {
		os.rm(path) or {}
	}
	run_cli(['import', 'family', path], mut st, SendResult{})
	st.set_email_member_status('family', 'ada@example.com', member_unsubscribed, '') or { panic(err) }
	out, code, _ := run_cli(['import', 'family', path], mut st, SendResult{})
	assert code == 0 && out.contains('0 added, 2 already there') && !out.contains('new group')
	assert (st.get_email_member('family', 'ada@example.com') or { panic('gone') }).status == member_unsubscribed
}

fn test_import_takes_a_note_about_where_the_consent_came_from() {
	mut st := cli_store()
	path := temp_list('c', 'ada@example.com\n')
	defer {
		os.rm(path) or {}
	}
	run_cli(['import', 'family', path, 'asked', 'at', 'the', 'club', 'meeting'], mut st, SendResult{})
	assert (st.get_email_member('family', 'ada@example.com') or { panic('gone') }).note == 'asked at the club meeting'
}

fn test_import_refuses_a_bad_group_name_a_missing_file_and_missing_arguments() {
	mut st := cli_store()
	_, code1, _ := run_cli(['import', 'x', '/nonexistent'], mut st, SendResult{})
	assert code1 == 2
	out2, code2, _ := run_cli(['import', 'family', '/nonexistent/file.txt'], mut st, SendResult{})
	assert code2 == 1 && out2.contains('Cannot read')
	_, code3, _ := run_cli(['import', 'family'], mut st, SendResult{})
	assert code3 == 2
	assert st.list_email_groups().len == 0
}

fn test_groups_and_members_are_listed() {
	mut st := cli_store()
	path := temp_list('d', 'ada@example.com Ada\nbob@example.com\n')
	defer {
		os.rm(path) or {}
	}
	run_cli(['import', 'family', path], mut st, SendResult{})
	st.set_email_member_status('family', 'bob@example.com', member_rejected, 'Email address is not verified') or { panic(err) }
	g, _, _ := run_cli(['groups'], mut st, SendResult{})
	assert g == 'family: 1 active of 2'
	m, code, _ := run_cli(['members', 'family'], mut st, SendResult{})
	assert code == 0 && m.contains('ada@example.com\tAda\tactive') && m.contains('bob@example.com\t\trejected\tEmail address is not verified')
	none_out, none_code, _ := run_cli(['members', 'nope'], mut st, SendResult{})
	assert none_code == 1 && none_out.contains('No group nope')
}

fn test_no_groups_says_so() {
	mut st := cli_store()
	out, code, _ := run_cli(['groups'], mut st, SendResult{})
	assert code == 0 && out == 'No email groups.'
}

fn test_a_test_message_goes_to_the_address_and_says_what_happened() {
	mut st := cli_store()
	out, code, sender := run_cli(['test', 'Me@Example.com'], mut st, SendResult{ outcome: .sent, message_id: 'abc' })
	assert code == 0 && out == 'Sent to me@example.com (SES message abc).'
	assert sender.last.to == 'me@example.com' && sender.last.subject.contains('Test message')
	r_out, r_code, _ := run_cli(['test', 'me@example.com'], mut st, SendResult{ outcome: .rejected, error: 'Email address is not verified' })
	assert r_code == 1 && r_out == 'SES refused this address: Email address is not verified'
	h_out, h_code, _ := run_cli(['test', 'me@example.com'], mut st, SendResult{ outcome: .halt, error: 'sender not verified' })
	assert h_code == 1 && h_out == 'Cannot send: sender not verified'
	t_out, t_code, _ := run_cli(['test', 'me@example.com'], mut st, SendResult{ outcome: .retry, error: 'busy' })
	assert t_code == 1 && t_out.contains('could not take it just now')
}

fn test_a_test_to_something_that_is_not_an_address_is_refused_before_sending() {
	mut st := cli_store()
	out, code, sender := run_cli(['test', 'nonsense'], mut st, SendResult{})
	assert code == 2 && out.starts_with('Usage') && sender.last.to == ''
}

fn test_no_arguments_or_an_unknown_command_gives_the_usage() {
	mut st := cli_store()
	for a in [[]string{}, ['frobnicate']] {
		out, code, _ := run_cli(a, mut st, SendResult{})
		assert code == 2 && out.starts_with('meshbbs email'), '${a}'
	}
}

fn test_without_settings_a_test_says_what_is_missing() {
	mut st := cli_store()
	mut none_sender := EmailSender(NoMail{
		why: 'cannot read the SES settings at /x'
	})
	out, code := email_cli(['test', 'me@example.com'], mut st, mut none_sender, 1000)
	assert code == 1 && out == 'Cannot send: cannot read the SES settings at /x'
}

fn test_opening_a_worker_without_settings_turns_email_off_and_says_why() {
	os.setenv('MESHBBS_SES', '/nonexistent/ses.conf', true)
	defer {
		os.unsetenv('MESHBBS_SES')
	}
	mut st := cli_store()
	mut logged := []string{}
	w := open_email_worker(st, fn [mut logged] (s string) {
		logged << s
	})
	assert w.disabled == true
}

fn test_opening_a_worker_with_settings_turns_email_on() {
	path := temp_list('ses.conf', 'access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\n')
	os.setenv('MESHBBS_SES', path, true)
	defer {
		os.unsetenv('MESHBBS_SES')
		os.rm(path) or {}
	}
	mut st := cli_store()
	w := open_email_worker(st, fn (s string) {})
	assert w.disabled == false
}

// log lines held by reference, so a closure handed it can add to them
struct CliLog {
mut:
	lines []string
}

fn (mut l CliLog) add(s string) {
	l.lines << s
}

fn inbound_with_settings(text string) (InboundWorker, []string) {
	path := temp_list('inbound.conf', text)
	os.setenv('MESHBBS_SES', path, true)
	defer {
		os.unsetenv('MESHBBS_SES')
		os.rm(path) or {}
	}
	rec := &CliLog{}
	w := open_inbound_worker(cli_store(), fn [rec] (s string) {
		rec.add(s)
	})
	return w, rec.lines
}

fn test_posting_by_email_is_off_without_settings_or_without_a_bucket_and_a_group() {
	os.setenv('MESHBBS_SES', '/nonexistent/ses.conf', true)
	defer {
		os.unsetenv('MESHBBS_SES')
	}
	rec := &CliLog{}
	mut none_at_all := open_inbound_worker(cli_store(), fn [rec] (s string) {
		rec.add(s)
	})
	assert none_at_all.disabled && rec.lines[0].contains('no SES settings')
	assert none_at_all.tick(1000) == false
	partial, lines := inbound_with_settings('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\ninbound_group=mesh\n')
	assert partial.disabled && lines[0].contains('no inbound_bucket and inbound_group')
}

fn test_posting_by_email_is_on_when_the_settings_name_a_bucket_and_a_group() {
	w, lines := inbound_with_settings('access_key_id=AK\nsecret_access_key=SK\nfrom=mesh@xerokuhl.com\nlist_address=meshbbs@xerokuhl.com\nreply_to=sysop@example.com\ninbound_bucket=my-mail-bucket\ninbound_group=mesh\n')
	assert !w.disabled && w.settings.address == 'meshbbs@xerokuhl.com' && w.settings.group == 'mesh' && w.contact == 'sysop@example.com'
	assert lines[0] == '[inbound] taking in mail sent to meshbbs@xerokuhl.com from s3://my-mail-bucket/inbound/ for the mesh list'
}

fn test_a_disabled_worker_sends_nothing_and_keeps_the_queue() {
	mut st := cli_store()
	st.enqueue_email('a@example.com', 's', 'b', 'g', 1) or { panic(err) }
	mut w := EmailWorker{
		store:    st
		sender:   NoMail{
			why: 'no settings'
		}
		disabled: true
	}
	assert w.tick(5000) == false
	assert st.count_emails(email_queued) == 1
}
