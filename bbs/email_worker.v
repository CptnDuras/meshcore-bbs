module main

// Drains the email queue, one message per call, so the daemon's one-second loop keeps to SES's sending rate (1 a second in the sandbox).
//
//   sent      -> marked sent
//   rejected  -> marked failed, and that group member marked 'rejected' (their address is not usable; the sysop can look)
//   retry     -> kept, tried again later (1 min, 5 min, 30 min, 2 h, 6 h, 12 h), failed after the last
//   halt      -> every message stays queued and the worker rests for a quarter of an hour: the sysop has to fix the setup (credentials, sender not verified)
//
// The account's own daily limit is respected with a cap a little under it, so a long list can never run the account into SES's limit.

interface EmailSender {
mut:
	send(msg EmailMsg, now i64) SendResult
}

const email_retry_secs = [i64(60), 300, 1800, 7200, 21600, 43200]
const email_halt_rest = i64(900)

struct EmailWorker {
pub mut:
	store        Store
	sender       EmailSender
	daily_cap    int = 150
	paused_until i64
	last_halt    string // why the worker last stopped, for EMAILSTATUS and the log
	capped       bool   // true while the daily cap is holding messages back
	disabled     bool   // no SES settings: nothing is sent and the queue just fills
	last_prune   i64
	log          fn (string) = fn (s string) {}
}

// finished mail (sent or failed) is kept this long, then removed
const email_keep_secs = i64(30 * 86400)

// -> true if a message was attempted
fn (mut w EmailWorker) tick(now i64) bool {
	if w.disabled {
		return false
	}
	if now - w.last_prune >= 6 * 3600 {
		w.last_prune = now
		w.store.prune_emails(now - email_keep_secs) or {}
	}
	if now < w.paused_until {
		return false
	}
	if w.store.count_emails_sent_since(now - 86400) >= w.daily_cap {
		w.capped = true
		return false
	}
	w.capped = false
	due := w.store.due_emails(now, 1)
	if due.len == 0 {
		return false
	}
	m := due[0]
	if !valid_email(m.to_addr) {
		w.store.mark_email_failed(m.id, 'not an email address') or {}
		return true
	}
	r := w.sender.send(EmailMsg{ to: m.to_addr, subject: m.subject, text: m.body }, now)
	match r.outcome {
		.sent {
			w.store.mark_email_sent(m.id, r.message_id, now) or {}
			w.store.touch_email_member_sent(m.to_addr, now) or {}
		}
		.rejected {
			w.log('[email] ${m.to_addr} refused: ${r.error}')
			w.store.mark_email_failed(m.id, r.error) or {}
			if m.group_name != '' {
				w.store.set_email_member_status(m.group_name, m.to_addr, member_rejected, r.error) or {}
			}
		}
		.retry {
			next := m.attempts + 1
			if next >= email_retry_secs.len {
				w.store.mark_email_failed(m.id, 'gave up after ${next} tries: ${r.error}') or {}
			} else {
				w.store.retry_email_later(m.id, r.error, now + email_retry_secs[m.attempts]) or {}
			}
		}
		.halt {
			w.paused_until = now + email_halt_rest
			w.last_halt = r.error
			w.log('[email] stopped for ${email_halt_rest / 60} minutes, mail stays queued: ${r.error}')
		}
	}
	return true
}
