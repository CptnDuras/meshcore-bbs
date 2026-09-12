module main

fn rl_engine(interval i64) Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store:             store
		name:              'rlbbs'
		min_turn_interval: interval
		last_turn:         map[string]i64{}
	}
}

// --- pure decision function ---

fn test_rate_limit_disabled_when_zero() {
	assert rate_limit_decision(100, 101, 0) == true
}

fn test_rate_limit_first_turn_allowed() {
	assert rate_limit_decision(0, 1000, 5) == true
}

fn test_rate_limit_blocks_within_window() {
	assert rate_limit_decision(1000, 1002, 5) == false
}

fn test_rate_limit_allows_after_window() {
	assert rate_limit_decision(1000, 1005, 5) == true
	assert rate_limit_decision(1000, 1006, 5) == true
}

// --- engine map-based check ---

fn test_check_rate_limit_updates_and_throttles() {
	mut e := rl_engine(5)
	assert e.check_rate_limit('nodeA', 1000) == true // first
	assert e.check_rate_limit('nodeA', 1002) == false // too soon
	assert e.check_rate_limit('nodeA', 1006) == true // window passed
	// a different node is independent
	assert e.check_rate_limit('nodeB', 1006) == true
}

// --- end-to-end through handle() ---

fn test_handle_throttles_fast_turns() {
	mut e := rl_engine(5)
	// NOTE: handle() uses real time; two immediate calls are within 5s.
	first := e.handle('spammer', 'HELP')
	assert !first.contains('Slow down')
	second := e.handle('spammer', 'HELP')
	assert second.contains('Slow down')
}

fn test_handle_no_limit_when_disabled() {
	mut e := rl_engine(0) // disabled
	a := e.handle('nodeA', 'HELP')
	b := e.handle('nodeA', 'HELP')
	assert !a.contains('Slow down')
	assert !b.contains('Slow down')
}
