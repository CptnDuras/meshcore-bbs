module main

// Polls (Spec 11 NICE tier): interactive voting.
//
// Commands:
//   POLL                         list open polls (most recent first)
//   POLL <id>                    show a poll's question + numbered options
//   POLL NEW <q>|<opt>|<opt>...  create a poll (verified users)
//   VOTE <id> <n>                cast a vote for option n on poll id
//   RESULTS <id>                 show the tally for a poll
//   POLLCLOSE <id>               close a poll (author or aide+)
//
// Votes are keyed by the caller's pubkey prefix (sess.pubkey_prefix), so each
// node votes at most once per poll — works for guests and users alike.

// polls is the POLL command entry point; args decides sub-behaviour.
fn (mut e Engine) polls(mut sess Session, args string) string {
	a := args.trim_space()
	if a.len == 0 {
		return e.list_polls_view()
	}
	// "POLL NEW ..." creates; otherwise treat the arg as a poll id to show.
	parts := a.split(' ')
	if parts[0].to_upper() == 'NEW' {
		rest := if parts.len > 1 { parts[1..].join(' ') } else { '' }
		return e.create_poll_cmd(mut sess, rest)
	}
	id := parts[0].int()
	if id <= 0 {
		return 'Usage: POLL | POLL <id> | POLL NEW <question>|<opt>|<opt>...'
	}
	return e.show_poll(id)
}

fn (mut e Engine) list_polls_view() string {
	polls := e.store.list_polls(10)
	if polls.len == 0 {
		return 'No polls yet. POLL NEW <question>|<opt>|<opt> to create one.'
	}
	mut b := '== Polls ==\n'
	for p in polls {
		status := if p.closed { ' (closed)' } else { '' }
		b += '#${p.id} ${p.question}${status}\n'
	}
	b += 'POLL <id> to view, VOTE <id> <n> to vote.'
	return b
}

fn (mut e Engine) show_poll(id int) string {
	p := e.store.get_poll(id) or { return 'No such poll #${id}.' }
	opts := p.options.split('\n')
	mut b := '#${p.id} ${p.question}'
	if p.closed {
		b += ' (closed)'
	}
	b += '\n'
	for i, opt in opts {
		b += '${i + 1}) ${opt}\n'
	}
	b += 'VOTE ${p.id} <n> to vote.'
	return b
}

fn (mut e Engine) create_poll_cmd(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN to create a poll.' }
	if !has_permission(user, 'poll_create') {
		return 'You are not verified yet.'
	}
	// format: <question>|<opt1>|<opt2>[|...]
	parts := args.split('|')
	if parts.len < 3 {
		return 'Usage: POLL NEW <question>|<option1>|<option2>[|...]'
	}
	question := parts[0].trim_space()
	mut opts := []string{}
	for raw in parts[1..] {
		o := raw.trim_space()
		if o.len > 0 {
			opts << o
		}
	}
	if question.len == 0 {
		return 'Poll question cannot be empty.'
	}
	if opts.len < 2 {
		return 'A poll needs at least 2 options.'
	}
	p := e.store.create_poll(question, opts, user.handle) or { return 'Failed: ${err}' }
	return 'Poll #${p.id} created with ${opts.len} options. Share: VOTE ${p.id} <n>.'
}

fn (mut e Engine) vote(mut sess Session, args string) string {
	parts := args.trim_space().split(' ')
	if parts.len < 2 {
		return 'Usage: VOTE <poll-id> <option-number>'
	}
	id := parts[0].int()
	choice := parts[1].int()
	if id <= 0 || choice <= 0 {
		return 'Usage: VOTE <poll-id> <option-number>'
	}
	// One vote per node, keyed by pubkey prefix.
	e.store.add_vote(id, sess.pubkey_prefix, choice) or { return 'Vote failed: ${err}' }
	return 'Vote recorded for poll #${id}. RESULTS ${id} to see the tally.'
}

fn (mut e Engine) poll_results(args string) string {
	id := args.trim_space().int()
	if id <= 0 {
		return 'Usage: RESULTS <poll-id>'
	}
	p := e.store.get_poll(id) or { return 'No such poll #${id}.' }
	opts := p.options.split('\n')
	counts := e.store.poll_tally(id)
	mut total := 0
	for c in counts {
		total += c
	}
	mut b := 'Results #${p.id}: ${p.question}\n'
	for i, opt in opts {
		n := if i < counts.len { counts[i] } else { 0 }
		pct := if total > 0 { int(f64(n) * 100.0 / f64(total)) } else { 0 }
		b += '${i + 1}) ${opt}: ${n} (${pct}%)\n'
	}
	b += 'Total votes: ${total}'
	if p.closed {
		b += ' (closed)'
	}
	return b
}

fn (mut e Engine) close_poll_cmd(mut sess Session, args string) string {
	user := e.current_user(sess) or { return 'You must LOGIN.' }
	id := args.trim_space().int()
	if id <= 0 {
		return 'Usage: POLLCLOSE <poll-id>'
	}
	p := e.store.get_poll(id) or { return 'No such poll #${id}.' }
	// The author may close their own poll; aides+ may close any.
	is_author := p.author == user.handle
	if !is_author && !has_permission(user, 'delete_message') {
		return 'Only the poll author or an aide can close it.'
	}
	e.store.close_poll(id) or { return 'Failed: ${err}' }
	return 'Poll #${id} closed.'
}
