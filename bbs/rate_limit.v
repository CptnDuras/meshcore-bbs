module main

// Rate limiting — mesh self-defense (meshcore-bot parity).
//
// A shared LoRa mesh has scarce airtime; a chatty or misbehaving node can
// starve everyone. We enforce a minimum interval between *accepted* turns from
// the same node. When a node exceeds the rate, we return a terse notice and do
// NOT process the command (so no DB work and no long reply are generated).
//
// The decision is a pure function so it can be tested with an injected clock.

// rate_limit_decision returns whether a turn from a node is allowed given the
// node's last accepted turn time, the current time, and the minimum interval.
// An interval <= 0 disables limiting (always allowed).
fn rate_limit_decision(last_turn i64, now i64, min_interval i64) bool {
	if min_interval <= 0 {
		return true
	}
	if last_turn <= 0 {
		return true // first turn from this node
	}
	return (now - last_turn) >= min_interval
}

// check_rate_limit consults and updates the engine's per-node last-turn map.
// Returns true if the turn is allowed (and records `now` as the node's last
// accepted turn); false if it should be throttled.
fn (mut e Engine) check_rate_limit(pubkey_prefix string, now i64) bool {
	last := e.last_turn[pubkey_prefix] or { 0 }
	if !rate_limit_decision(last, now, e.min_turn_interval) {
		return false
	}
	e.last_turn[pubkey_prefix] = now
	return true
}
