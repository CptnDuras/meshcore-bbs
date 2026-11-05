module main

import emaillist

// Takes in the mail people send to the list address. SES leaves each message in a bucket (tools/ses-inbound-setup.sh); every minute this looks there,
// reads what it finds, applies the rules in inbound.v, and for each message either
//   - passes it on: one queued email per active member of the group except the sender (the EmailWorker sends them), the subject tagged;
//   - takes the sender off the list, if the message is just "STOP"; or
//   - turns it away, writing down why.
// Every message gets a row in email_inbound before anything is done with it, so it is handled at most once: if the daemon stops half way, the row stays as
// 'posting' for the sysop to see, and the message is not sent a second time. The message is deleted from the bucket afterwards either way (it is not
// kept: only who sent it, the subject and what was done are).

const inbound_keep_secs = i64(90 * 86400)
const inbound_fetch_tries = 5
const inbound_per_poll = 20

struct InboundWorker {
pub mut:
	store      Store
	objects    ObjectStore
	settings   InboundSettings
	contact    string // where a person can write to the sysop, for the confirmation of a STOP ('' leaves that sentence out)
	daily_cap  int = 150
	disabled   bool // posting by email is not set up: nothing is looked at
	poll_secs  i64 = 60
	last_poll  i64
	last_prune i64
	failures   map[string]int // times fetching each message has failed
	log        fn (string) = fn (s string) {}
}

// -> true if it looked in the bucket
fn (mut w InboundWorker) tick(now i64) bool {
	if w.disabled || now - w.last_poll < w.poll_secs {
		return false
	}
	w.last_poll = now
	if now - w.last_prune >= 6 * 3600 {
		w.last_prune = now
		w.store.prune_inbound(now - inbound_keep_secs) or {}
	}
	// what the web page shows: where it listens, when it last looked, and what went wrong
	w.store.set_email_setting(emaillist.setting_inbound_address, w.settings.address) or {}
	w.store.set_email_setting(emaillist.setting_inbound_group, w.settings.group) or {}
	w.store.set_email_setting(emaillist.setting_inbound_poll, now.str()) or {}
	if _ := w.store.get_email_group(w.settings.group) {
	} else {
		problem := 'there is no email group called ${w.settings.group}, so mail to ${w.settings.address} is being left in the bucket'
		w.log('[inbound] ${problem}')
		w.store.set_email_setting(emaillist.setting_inbound_error, problem) or {}
		return true
	}
	found := w.objects.list(inbound_per_poll) or {
		w.log('[inbound] could not look in the bucket: ${err.msg()}')
		w.store.set_email_setting(emaillist.setting_inbound_error, 'could not look in the bucket: ${err.msg()}') or {}
		return true
	}
	w.store.set_email_setting(emaillist.setting_inbound_error, '') or {}
	for obj in found {
		w.handle(obj, now)
	}
	return true
}

fn (mut w InboundWorker) forget(key string) {
	w.objects.delete(key) or { w.log('[inbound] could not delete ${key}: ${err.msg()} (it will not be handled again)') }
	w.failures.delete(key)
}

fn (mut w InboundWorker) reject_unread(key string, now i64, status string, reason string) {
	w.store.inbound_begin(key, now) or {}
	w.store.inbound_finish(key, '', '', '', '', status, reason, 0) or {}
	w.forget(key)
}

fn (mut w InboundWorker) handle(obj ObjectInfo, now i64) {
	key := obj.key
	// one that was handled already (its delete failed last time): just remove it
	if w.store.inbound_status(key) != '' {
		w.forget(key)
		return
	}
	if obj.size > w.settings.max_bytes {
		w.log('[inbound] ${key} turned away: too large (${obj.size} bytes)')
		w.reject_unread(key, now, emaillist.inbound_rejected, 'too large (${obj.size} bytes, the limit is ${w.settings.max_bytes})')
		return
	}
	raw := w.objects.get(key) or {
		w.failures[key]++
		w.log('[inbound] could not fetch ${key} (try ${w.failures[key]}): ${err.msg()}')
		if w.failures[key] >= inbound_fetch_tries {
			w.reject_unread(key, now, emaillist.inbound_failed, 'could not be fetched: ${err.msg()}')
		}
		return
	}
	began := w.store.inbound_begin(key, now) or { false }
	if !began {
		w.forget(key)
		return
	}
	mail := parse_mail(raw)
	senders_active := w.store.list_email_members(w.settings.group).filter(it.status == emaillist.member_active)
	others := senders_active.filter(it.email != mail.from_addr)
	facts := InboundFacts{
		mail:               mail
		raw_size:           raw.len
		paused:             w.store.get_email_setting(emaillist.setting_inbound_paused) == '1'
		blocked:            mail.from_addr != '' && w.store.is_blocked_sender(mail.from_addr)
		sender_posts_today: if mail.from_addr != '' {
			w.store.count_posts_by(mail.from_addr, now - 86400)
		} else {
			0
		}
		posts_today:        w.store.count_inbound(emaillist.inbound_posted, now - 86400)
		members:            others.len
		queued:             w.store.count_emails(email_queued)
		daily_cap:          w.daily_cap
	}
	d := decide(w.settings, facts)
	subject := mail.subject
	match d.kind {
		.reject {
			w.log('[inbound] ${mail.from_addr}: "${subject}" turned away: ${d.reason}')
			w.store.inbound_finish(key, mail.message_id, mail.from_addr, mail.from_name, subject, emaillist.inbound_rejected, d.reason, 0) or {}
		}
		.stop {
			w.finish_stop(key, mail, now)
		}
		.post {
			n := w.pass_on(mail, others, now)
			w.log('[inbound] ${mail.from_addr}: "${subject}" passed on to ${n} people')
			w.store.inbound_finish(key, mail.message_id, mail.from_addr, mail.from_name, subject, emaillist.inbound_posted, '', n) or {}
		}
	}
	w.forget(key)
}

// One queued email for each of the others on the list.
fn (mut w InboundWorker) pass_on(mail ParsedMail, others []EmailMember, now i64) int {
	subject := tag_subject(w.settings.tag, mail.subject)
	body := compose_post_body(w.settings, mail)
	from := poster_name(mail)
	mut n := 0
	for m in others {
		w.store.enqueue_post_email(m.email, subject, body, w.settings.group, from, now) or {
			w.log('[inbound] could not queue mail to ${m.email}: ${err.msg()}')
			continue
		}
		n++
	}
	return n
}

// "STOP" from someone on the list takes them off it, and they are told so. From anyone else it changes nothing.
fn (mut w InboundWorker) finish_stop(key string, mail ParsedMail, now i64) {
	member := w.store.get_email_member(w.settings.group, mail.from_addr) or {
		w.store.inbound_finish(key, mail.message_id, mail.from_addr, mail.from_name, mail.subject, emaillist.inbound_rejected, 'asked to stop, but is not on the list', 0) or {}
		return
	}
	if member.status != emaillist.member_unsubscribed {
		w.store.set_email_member_status(w.settings.group, member.email, emaillist.member_unsubscribed, '') or {
			w.log('[inbound] could not take ${member.email} off the list: ${err.msg()}')
			return
		}
		more := if w.contact != '' { ' If that was a mistake, write to ${w.contact}.' } else { '' }
		w.store.enqueue_email(member.email, 'You are off the ${w.settings.list_name} list', 'You asked to stop, so you will get no more mail from the ${w.settings.list_name} list.${more}\n',
			w.settings.group, now) or {}
	}
	w.log('[inbound] ${member.email} asked to stop and is off the list')
	w.store.inbound_finish(key, mail.message_id, mail.from_addr, mail.from_name, mail.subject, emaillist.inbound_stopped, '', 0) or {}
}
