module main

import time

// STATS: node/BBS statistics (TC2-BBS + meshcore-bot parity).
// Powered by the existing tables + the interaction audit log + process uptime.

fn (mut e Engine) stats() string {
	users := e.store.count_users()
	msgs := e.store.count_messages()
	boards := e.store.count_boards()
	polls := e.store.count_polls()
	chans := e.store.count_channels()

	now := time.now().unix()
	day_ago := now - (24 * 60 * 60)
	active := e.store.active_nodes_since(day_ago)

	known_names := e.store.count_node_names()
	traffic := e.store.count_traffic()
	heard := e.store.traffic_nodes_since(day_ago)

	mut b := '== ${e.name} stats ==\n'
	b += 'Users: ${users}  Msgs: ${msgs}  Boards: ${boards}\n'
	b += 'Polls: ${polls}  Channels: ${chans}\n'
	b += 'Active nodes (24h): ${active}\n'
	b += 'Known node names: ${known_names}\n'
	b += 'Mesh pkts seen: ${traffic}  nodes heard (24h): ${heard}\n'
	b += 'Uptime: ${format_uptime(e.started, now)}'
	return b
}

// format_uptime renders elapsed time since `started` as "Nd Nh Nm".
// Pure -> unit testable. If started is 0/unset, reports "unknown".
fn format_uptime(started i64, now i64) string {
	if started <= 0 || now < started {
		return 'unknown'
	}
	mut secs := now - started
	days := secs / 86400
	secs = secs % 86400
	hours := secs / 3600
	secs = secs % 3600
	mins := secs / 60
	return '${days}d ${hours}h ${mins}m'
}
