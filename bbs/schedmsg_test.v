module main

fn sm_store() Store {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return store
}

// --- pure due logic ---

fn mk_sched(kind string) ScheduledMessage {
	return ScheduledMessage{
		target_kind: target_chan
		target:      '0'
		text:        'hi'
		sched_kind:  kind
		enabled:     true
	}
}

fn test_onetime_due_when_time_reached() {
	mut m := mk_sched(sched_onetime)
	m.run_at = 1000
	assert scheduled_due(m, 999, 0) == false
	assert scheduled_due(m, 1000, 0) == true
	assert scheduled_due(m, 1500, 0) == true
}

fn test_onetime_not_due_after_run() {
	mut m := mk_sched(sched_onetime)
	m.run_at = 1000
	m.last_run = 1000
	assert scheduled_due(m, 2000, 0) == false
}

fn test_disabled_never_due() {
	mut m := mk_sched(sched_onetime)
	m.run_at = 1000
	m.enabled = false
	assert scheduled_due(m, 2000, 0) == false
}

fn test_interval_due_logic() {
	mut m := mk_sched(sched_interval)
	m.interval_secs = 60
	assert scheduled_due(m, 1000, 0) == true // never run
	m.last_run = 1000
	assert scheduled_due(m, 1030, minute_of_day(1030)) == false
	assert scheduled_due(m, 1060, minute_of_day(1060)) == true
}

fn test_daily_due_logic() {
	mut m := mk_sched(sched_daily)
	m.daily_minute = 480 // 08:00
	now := i64(480 * 60)
	assert scheduled_due(m, now, minute_of_day(now)) == true
	// wrong minute
	other := i64(481 * 60)
	assert scheduled_due(m, other, minute_of_day(other)) == false
	// already ran this minute
	m.last_run = now
	assert scheduled_due(m, now, minute_of_day(now)) == false
}

// --- outbound queue store ---

fn test_outbound_enqueue_and_pending() {
	mut s := sm_store()
	s.enqueue_outbound(target_chan, '0', 'hello channel') or { panic(err) }
	s.enqueue_outbound(target_dm, '4b81424f7106', 'hello node') or { panic(err) }
	assert s.count_outbound_pending() == 2
	pend := s.pending_outbound(10)
	assert pend.len == 2
	assert pend[0].target_kind == target_chan
	assert pend[0].target == '0'
	assert pend[1].target_kind == target_dm
}

fn test_outbound_mark_sent() {
	mut s := sm_store()
	s.enqueue_outbound(target_chan, '0', 'x') or { panic(err) }
	pend := s.pending_outbound(10)
	s.mark_outbound_sent(pend[0].id) or { panic(err) }
	assert s.count_outbound_pending() == 0
}

// --- scheduled store ---

fn test_scheduled_add_and_list() {
	mut s := sm_store()
	s.add_scheduled(ScheduledMessage{
		target_kind: target_chan
		target:      '0'
		text:        'daily wx'
		sched_kind:  sched_daily
		daily_minute: 420
		enabled:     true
	}) or { panic(err) }
	list := s.list_scheduled(10)
	assert list.len == 1
	assert list[0].text == 'daily wx'
	assert list[0].daily_minute == 420
}

fn test_scheduled_enable_disable_delete() {
	mut s := sm_store()
	m := s.add_scheduled(ScheduledMessage{
		target_kind: target_chan
		target:      '0'
		text:        'x'
		sched_kind:  sched_interval
		interval_secs: 60
		enabled:     true
	}) or { panic(err) }
	s.set_scheduled_enabled(m.id, false) or { panic(err) }
	got := s.get_scheduled(m.id) or { panic('exists') }
	assert got.enabled == false
	s.mark_scheduled_run(m.id, 12345) or { panic(err) }
	got2 := s.get_scheduled(m.id) or { panic('exists') }
	assert got2.last_run == 12345
	s.delete_scheduled(m.id) or { panic(err) }
	if _ := s.get_scheduled(m.id) {
		assert false, 'should be deleted'
	}
	assert true
}

// --- source resolver ---

fn test_resolve_source_static_returns_text() {
	mut e := Engine{ store: sm_store(), name: 'r' }
	assert e.resolve_source(src_static, 'hello world') == 'hello world'
}

fn test_resolve_source_unknown_falls_back_to_static() {
	mut e := Engine{ store: sm_store(), name: 'r' }
	assert e.resolve_source('bogus', 'fallback text') == 'fallback text'
}

fn test_resolve_source_fortune_nonempty() {
	// fortune uses the embedded list (no file needed) -> always non-empty
	mut e := Engine{ store: sm_store(), name: 'r' }
	out := e.resolve_source(src_fortune, '')
	assert out.starts_with('Fortune: ')
}

fn test_source_constants() {
	assert src_static == 'static'
	assert src_wx == 'wx'
	assert src_news == 'news'
	assert src_digest == 'digest'
}

// --- idempotent seeding support ---

fn test_count_scheduled_by_source() {
	mut s := sm_store()
	assert s.count_scheduled_by_source(src_digest, 420) == 0
	s.add_scheduled(ScheduledMessage{
		target_kind:  target_chan
		target:       '0'
		text:         'Morning digest'
		source:       src_digest
		sched_kind:   sched_daily
		daily_minute: 420
		enabled:      true
	}) or { panic(err) }
	assert s.count_scheduled_by_source(src_digest, 420) == 1
	// different minute -> not counted
	assert s.count_scheduled_by_source(src_digest, 421) == 0
}
