module main

import time

fn stats_engine() Engine {
	mut store := new_store('sqlite::memory:') or { panic(err) }
	store.migrate() or {}
	store.ensure_board('general', 'General') or {}
	return Engine{
		store:   store
		name:    'statbbs'
		started: time.now().unix() - 3661 // ~1h 1m ago
	}
}

fn test_format_uptime() {
	assert format_uptime(0, 100) == 'unknown'
	assert format_uptime(100, 50) == 'unknown' // now before started
	// 1 day, 2 hours, 3 minutes, 4 seconds
	start := i64(1_000_000)
	now := start + (1 * 86400) + (2 * 3600) + (3 * 60) + 4
	assert format_uptime(start, now) == '1d 2h 3m'
}

fn test_stats_reports_counts() {
	mut e := stats_engine()
	e.handle('aa', 'NEW sysop pw') // 1 user
	s := e.handle('aa', 'STATS')
	assert s.contains('statbbs stats')
	assert s.contains('Users: 1')
	assert s.contains('Boards: 1')
	assert s.contains('Uptime:')
}

fn test_stats_active_nodes() {
	mut e := stats_engine()
	// three distinct nodes interact -> each logged in the audit table
	e.handle('nodeA', 'HELP')
	e.handle('nodeB', 'HELP')
	e.handle('nodeC', 'HELP')
	s := e.handle('nodeA', 'STATS')
	// nodeA..C plus this STATS turn are all within 24h
	assert s.contains('Active nodes (24h): 3')
}

fn test_stats_counts_channels_and_polls() {
	mut e := stats_engine()
	e.handle('aa', 'NEW sysop pw')
	e.handle('aa', 'POLL NEW q?|a|b')
	e.handle('aa', 'CHANADD Net|desc')
	s := e.handle('aa', 'STATS')
	assert s.contains('Polls: 1')
	assert s.contains('Channels: 1')
}
