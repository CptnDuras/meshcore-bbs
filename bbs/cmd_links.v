module main

import time

// LINKS shows what the link scan has measured between repeaters; LINKSCAN (sysop) asks the daemon to run a scan now, on top of the four it runs
// each day. The scan itself is in linkscan_run.v and runs in the daemon's loop.

fn (mut e Engine) node_label_map() map[string]string {
	mut m := map[string]string{}
	for n in e.store.list_node_names(8000) {
		m[n.pubkey_prefix.to_lower()] = n.name
	}
	return m
}

fn (mut e Engine) links() string {
	names := e.node_label_map()
	name_of := fn [names] (id string) string {
		if id == link_self {
			return 'BBS'
		}
		short := if id.len < 6 { id.len } else { 6 }
		return names[id] or { id[..short] }
	}
	edges := e.store.list_link_edges()
	rows := link_rows(edges, e.store.list_link_hops(), name_of)
	scans := e.store.recent_link_scans(1)
	mut last := ?LinkScan(none)
	if scans.len > 0 {
		last = scans[0]
	}
	return links_summary(rows, edges.filter(it.oks == 0).len, last, time.now().unix())
}

fn (mut e Engine) link_scan_cmd(mut sess Session) string {
	actor := e.current_user(sess) or { return 'You must LOGIN.' }
	if !has_permission(actor, 'linkscan') {
		return 'Permission denied (SYSOP required).'
	}
	e.store.request_link_scan('sysop', time.now().unix()) or { return 'Could not queue a scan: ${err}' }
	return 'Link scan queued. It runs in the background and can take a while; LINKS shows the results.'
}
