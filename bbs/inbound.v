module main

import emaillist

// Mail sent to the list address (meshbbs@xerokuhl.com): what to do with each message. Anyone may write to the list, so this is where the list is kept from
// being used against its members. Everything here is a pure function of the message and a few facts about the list, so each rule can be tested alone;
// inbound_worker.v gathers the facts and acts on the answer.
//
// A message is turned away (with a reason the sysop can read on the web page) if it is paused, too big, from no usable address, from the list itself,
// automatic or bulk mail (which is how mail loops start), from a blocked sender, not cleared by SES's spam and virus scans, not shown to come from
// where it says, empty, or would go over the limits. A message that is just "STOP" is not passed on: it takes the sender off the list.

struct InboundSettings {
pub:
	address      string // the list address, lower case
	group        string
	tag          string
	list_name    string
	bucket       string
	prefix       string
	max_bytes    int
	per_sender   int
	posts_day    int
	require_scan bool
	require_auth bool
}

// none unless the settings name a bucket and a group: posting by email is off until then
fn inbound_settings(c SesConfig) ?InboundSettings {
	if c.inbound_bucket == '' || c.inbound_group == '' || c.list_address == '' {
		return none
	}
	return InboundSettings{
		address:      c.list_address
		group:        c.inbound_group
		tag:          c.subject_tag
		list_name:    if c.list_name != '' { c.list_name } else { 'the mesh' }
		bucket:       c.inbound_bucket
		prefix:       c.inbound_prefix
		max_bytes:    c.inbound_max_bytes
		per_sender:   c.inbound_per_sender
		posts_day:    c.inbound_posts_day
		require_scan: c.require_scan
		require_auth: c.require_auth
	}
}

// What the worker knows about the list when it asks.
struct InboundFacts {
pub:
	mail               ParsedMail
	raw_size           int
	paused             bool
	blocked            bool
	sender_posts_today int // posts from this sender in the last 24 hours
	posts_today        int // posts from everyone in the last 24 hours
	members            int // people who would get it
	queued             int // emails waiting to be sent
	daily_cap          int // the most emails sent in a day (see EmailWorker)
}

enum InboundKind {
	post   // pass it on to the list
	stop   // the sender asked to be taken off
	reject // turn it away
}

struct InboundDecision {
pub:
	kind   InboundKind
	reason string
}

fn rejected(reason string) InboundDecision {
	return InboundDecision{
		kind:   .reject
		reason: reason
	}
}

// ---- reading what the receiving service and the sender say about a message ----

// Automatic and bulk mail: auto-replies, bounces, newsletters, other lists and our own mail coming back. '' if it looks like a person wrote it.
fn automatic_reason(m ParsedMail, list_address string) string {
	if m.header('x-loop').to_lower().contains(list_address.to_lower()) {
		return "the list's own mail coming back"
	}
	auto := m.header('auto-submitted').trim_space().to_lower()
	if auto != '' && auto != 'no' {
		return 'automatic mail (Auto-Submitted)'
	}
	if m.header('precedence').trim_space().to_lower() in ['bulk', 'junk', 'list', 'auto_reply'] {
		return 'bulk or list mail (Precedence)'
	}
	if m.header('x-auto-response-suppress') != '' {
		return 'automatic mail (X-Auto-Response-Suppress)'
	}
	if m.header('list-id') != '' || m.header('list-unsubscribe') != '' {
		return 'mail from another mailing list or a newsletter'
	}
	if m.header('content-type').to_lower().starts_with('multipart/report') {
		return 'a delivery report'
	}
	return_path := m.header_all('return-path')
	if return_path.len > 0 && return_path[0].trim_space().trim('<>').trim_space() == '' {
		return 'a bounce (empty return path)'
	}
	local := m.from_addr.all_before('@')
	if local in ['mailer-daemon', 'postmaster', 'noreply', 'no-reply', 'donotreply', 'do-not-reply',
		'bounce', 'bounces']
		|| local.starts_with('noreply') || local.starts_with('no-reply') {
		return 'from a no-reply or system address'
	}
	return ''
}

// What SES's spam and virus scans said. With require_scan, anything but a clear PASS is turned away (including a missing verdict, so a message that
// was never scanned is not passed on); FAIL is always turned away.
fn scan_problem(m ParsedMail, require bool) string {
	spam := m.header('x-ses-spam-verdict').trim_space().to_upper()
	virus := m.header('x-ses-virus-verdict').trim_space().to_upper()
	if spam == 'FAIL' {
		return 'flagged as spam'
	}
	if virus == 'FAIL' {
		return 'flagged as a virus'
	}
	if require && spam != 'PASS' {
		return 'not cleared by the spam scan (${if spam == '' { 'no verdict' } else { spam }})'
	}
	if require && virus != 'PASS' {
		return 'not cleared by the virus scan (${if virus == '' { 'no verdict' } else { virus }})'
	}
	return ''
}

// true if `domain` appears in `text` as a whole name (at the start of a name or as a parent of one: "x.com" in "mail.x.com" and "@x.com", not in "evilx.com")
fn has_domain(text string, domain string) bool {
	if domain == '' {
		return false
	}
	t := text.to_lower()
	d := domain.to_lower()
	mut from := 0
	for {
		i := t.index_after(d, from) or { return false }
		before := if i == 0 { ` ` } else { t[i - 1] }
		after_i := i + d.len
		after := if after_i >= t.len { ` ` } else { t[after_i] }
		is_name_char := fn (c u8) bool {
			return c.is_alnum() || c == `-`
		}
		if before in [`@`, `=`, ` `, `.`, `(`, `<`, `;`, `,`, `"`] && !is_name_char(after) && !(after == `.` && after_i + 1 < t.len && is_name_char(t[after_i + 1])) {
			return true
		}
		from = i + 1
	}
	return false
}

// Whether the message really came from the domain in its From line. The receiving service writes its SPF, DKIM and DMARC findings into
// Authentication-Results; a message passes if DMARC passed, or if DKIM or SPF passed for the From domain. '' if it does.
fn auth_problem(m ParsedMail) string {
	auth := m.header_all('authentication-results').join(' ').to_lower()
	if auth.contains('dmarc=fail') {
		return "the sender's domain says this mail is not from it (DMARC fail)"
	}
	if auth.contains('dmarc=pass') {
		return ''
	}
	domain := m.from_addr.all_after('@')
	if (auth.contains('dkim=pass') || auth.contains('spf=pass')) && has_domain(auth, domain) {
		return ''
	}
	spf := m.header('received-spf').trim_space().to_lower()
	if spf.starts_with('pass') && has_domain(spf, domain) {
		return ''
	}
	return 'the sender could not be verified (no SPF, DKIM or DMARC pass for ${domain})'
}

// The words a person types to get off a list.
const stop_words = ['stop', 'unsubscribe', 'unsub', 'remove me', 'remove', 'cancel', 'opt out',
	'optout', 'stop emails', 'stop email', 'stop emailing me', 'please unsubscribe', 'please remove me',
	'unsubscribe me', 'stop please', 'stop mailing me', 'take me off', 'take me off the list']

fn normalize_stop(s string) string {
	return s.to_lower().trim_space().trim_right('.!?, ').trim_left(' ').replace('  ', ' ')
}

// A message whose first line (not counting quoted text and blank lines) is just one of those words. If the body is empty the subject is read the same way,
// since "Subject: STOP" with nothing below is common.
fn is_stop_request(m ParsedMail) bool {
	for raw in m.text.split('\n') {
		line := raw.trim_space()
		if line == '' || line.starts_with('>') {
			continue
		}
		return normalize_stop(line) in stop_words
	}
	subject := normalize_stop(m.subject)
	subject_core := if subject.starts_with('re:') { normalize_stop(subject[3..]) } else { subject }
	return subject_core in stop_words
}

// ---- the decision ----

fn decide(s InboundSettings, f InboundFacts) InboundDecision {
	m := f.mail
	if f.raw_size > s.max_bytes {
		return rejected('too large (${f.raw_size} bytes, the limit is ${s.max_bytes})')
	}
	if m.from_addr == '' {
		return rejected('no usable sender address')
	}
	if m.from_addr == s.address {
		return rejected("sent from the list's own address")
	}
	why_auto := automatic_reason(m, s.address)
	if why_auto != '' {
		return rejected(why_auto)
	}
	if f.blocked {
		return rejected('the sender is blocked')
	}
	why_scan := scan_problem(m, s.require_scan)
	if why_scan != '' {
		return rejected(why_scan)
	}
	if s.require_auth {
		why_auth := auth_problem(m)
		if why_auth != '' {
			return rejected(why_auth)
		}
	}
	// getting off the list is allowed whatever else is going on (paused, limits)
	if is_stop_request(m) {
		return InboundDecision{
			kind: .stop
		}
	}
	if f.paused {
		return rejected('posting by email is paused')
	}
	if m.text.trim_space() == '' {
		return rejected('no text in the message')
	}
	if f.members == 0 {
		return rejected('nobody is on the list')
	}
	if f.sender_posts_today >= s.per_sender {
		return rejected('too many posts from this sender today (the limit is ${s.per_sender})')
	}
	// the list may not send more mail in a day than SES lets the account send
	by_quota := if f.daily_cap / f.members < 1 { 1 } else { f.daily_cap / f.members }
	limit := if by_quota < s.posts_day { by_quota } else { s.posts_day }
	if f.posts_today >= limit {
		return rejected('the list is at its limit for today (${limit} posts)')
	}
	if f.queued > 2 * f.daily_cap {
		return rejected('the sending queue is full')
	}
	return InboundDecision{
		kind: .post
	}
}

// ---- what is sent on ----

fn poster_name(m ParsedMail) string {
	n := emaillist.clean_name(m.from_name)
	return if n != '' { n } else { m.from_addr.all_before('@') }
}

// "[mesh] Re: Net tonight": the tag in front of the subject, once
fn tag_subject(tag string, subject string) string {
	mut s := subject.trim_space()
	if s == '' {
		s = '(no subject)'
	}
	if tag == '' {
		return s
	}
	if s.to_lower().starts_with(tag.to_lower()) {
		return s
	}
	// "Re: [mesh] x" already carries it
	if s.to_lower().contains(tag.to_lower()) && s.to_lower().starts_with('re:') {
		return s
	}
	return '${tag} ${s}'
}

// The text of a post: the poster's words, then a footer that says who wrote it, how to answer, and how to stop.
fn compose_post_body(s InboundSettings, m ParsedMail) string {
	body := m.text.trim_space()
	cut := if body.runes().len > email_body_limit {
		body.runes()[..email_body_limit].string() + '\n[cut]'
	} else {
		body
	}
	mut notes := ''
	if m.dropped > 0 {
		notes += '\n(${m.dropped} attachment${if m.dropped == 1 { ' was' } else { 's were' }} left out; this list carries text only.)'
	}
	if m.html_only {
		notes += '\n(This message was HTML; only its text is shown.)'
	}
	return '${cut}\n\n--\nPosted to the ${s.list_name} list by ${poster_name(m)} <${m.from_addr}>.${notes}\nReply to this email to answer everyone on the list, or write to ${m.from_addr} to answer only them.\nTo stop getting these, reply with the one word STOP.\n'
}
