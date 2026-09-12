module main

fn aging_store() Store {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	return store
}

// --- pure filter_fresh ---

fn test_filter_fresh_drops_seen() {
	all := ['A', 'B', 'C', 'D']
	mut seen := map[string]bool{}
	seen['A'] = true
	seen['C'] = true
	got := filter_fresh(all, seen, 10)
	assert got == ['B', 'D']
}

fn test_filter_fresh_respects_max() {
	all := ['A', 'B', 'C', 'D']
	seen := map[string]bool{}
	got := filter_fresh(all, seen, 2)
	assert got == ['A', 'B']
}

fn test_filter_fresh_all_seen_returns_empty() {
	all := ['A', 'B']
	mut seen := map[string]bool{}
	seen['A'] = true
	seen['B'] = true
	assert filter_fresh(all, seen, 5).len == 0
}

// --- build_news_report ---

fn test_build_report_normal() {
	out := build_news_report(['S1', 'S2'], ['B1'], false)
	assert out.contains('Sheridan Media')
	assert out.contains('- S1')
	assert out.contains('Buffalo Bulletin')
	assert out.contains('- B1')
}

fn test_build_report_all_stale_message() {
	out := build_news_report([], [], true)
	assert out.contains('No new headlines')
}

fn test_build_report_unreachable() {
	out := build_news_report([], [], false)
	assert out.contains('could not reach')
}

// --- store dedup ---

fn test_headline_seen_and_mark() {
	mut s := aging_store()
	assert s.headline_seen('Big News') == false
	s.mark_headline_sent('Big News') or { panic(err) }
	assert s.headline_seen('Big News') == true
	// idempotent: marking again doesn't error or duplicate
	s.mark_headline_sent('Big News') or { panic(err) }
	seen := s.seen_headlines()
	assert seen['Big News'] == true
	assert seen.len == 1
}

// --- end-to-end aging via engine (offline: no feed, exercises store path) ---

fn test_fetch_news_fresh_unreachable_is_graceful() {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	mut e := Engine{
		store: store
		name:  'newsbbs'
	}
	// no network in test env for these feeds is not guaranteed; just assert it
	// returns a string and doesn't crash. (Live behavior covered separately.)
	out := e.fetch_news_fresh()
	assert out.len > 0
}
