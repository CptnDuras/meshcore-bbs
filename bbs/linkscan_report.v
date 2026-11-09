module main

// The link scan's results as text for the LINKS command: how many links were measured and the best, weakest and slowest of them.

const summary_top = 3

// LinkRow is one measured link ready to show: its two ends by name, the average SNR each way (when that direction was heard) and the one-way delay.
pub struct LinkRow {
pub:
	a       string
	b       string
	snr_ab  f64
	has_ab  bool
	snr_ba  f64
	has_ba  bool
	lat_ms  int // average one-way delay
	oks     int
	tries   int
	depth   int
	last_ok i64
}

// weakest is the lower of the two directions' SNR, the one that limits the link.
pub fn (r LinkRow) weakest() f64 {
	if r.has_ab && r.has_ba {
		return if r.snr_ab < r.snr_ba { r.snr_ab } else { r.snr_ba }
	}
	return if r.has_ab { r.snr_ab } else { r.snr_ba }
}

pub fn (r LinkRow) has_snr() bool {
	return r.has_ab || r.has_ba
}

// link_rows joins the per-link and per-hop tables. name_of turns an id (or link_self) into something to show.
pub fn link_rows(edges []LinkEdge, hops []LinkHop, name_of fn (string) string) []LinkRow {
	mut avg := map[string]f64{}
	for h in hops {
		if h.n > 0 {
			avg['${h.from_id}>${h.to_id}'] = h.snr_sum / f64(h.n)
		}
	}
	mut out := []LinkRow{}
	for e in edges {
		if e.oks == 0 {
			continue
		}
		ab := avg['${e.a_id}>${e.b_id}'] or { 0.0 }
		ba := avg['${e.b_id}>${e.a_id}'] or { 0.0 }
		out << LinkRow{
			a:       name_of(e.a_id)
			b:       name_of(e.b_id)
			snr_ab:  ab
			has_ab:  '${e.a_id}>${e.b_id}' in avg
			snr_ba:  ba
			has_ba:  '${e.b_id}>${e.a_id}' in avg
			lat_ms:  if e.lat_n > 0 { int(e.lat_sum_ms / e.lat_n) } else { 0 }
			oks:     e.oks
			tries:   e.tries
			depth:   e.depth
			last_ok: e.last_ok_ts
		}
	}
	return out
}

fn snr_text(v f64) string {
	return '${v:.1f}'
}

fn link_line(r LinkRow) string {
	snr := if r.has_ab && r.has_ba {
		'${snr_text(r.snr_ab)}/${snr_text(r.snr_ba)}dB'
	} else if r.has_snr() {
		'${snr_text(r.weakest())}dB'
	} else {
		'no SNR'
	}
	return '${r.a}<>${r.b} ${snr} ${r.lat_ms}ms'
}

fn ago_text(secs i64) string {
	if secs < 90 {
		return '${secs}s'
	}
	if secs < 5400 {
		return '${(secs + 30) / 60}m'
	}
	if secs < 36 * 3600 {
		return '${(secs + 1800) / 3600}h'
	}
	return '${(secs + 43200) / 86400}d'
}

// links_summary is the answer to LINKS. unanswered is how many links were tried and never answered.
pub fn links_summary(rows []LinkRow, unanswered int, last ?LinkScan, now i64) string {
	mut b := ''
	if rows.len == 0 {
		b = 'No links measured yet.'
	} else {
		b = 'Links: ${rows.len} measured, ${unanswered} never answered\n'
		mut by_snr := rows.filter(it.has_snr())
		by_snr.sort(a.weakest() < b.weakest())
		if by_snr.len > 0 {
			b += 'Weakest:\n'
			for r in by_snr[..if by_snr.len < summary_top { by_snr.len } else { summary_top }] {
				b += ' ${link_line(r)}\n'
			}
			b += 'Strongest:\n'
			for r in by_snr.reverse()[..if by_snr.len < summary_top {
				by_snr.len
			} else {
				summary_top
			}] {
				b += ' ${link_line(r)}\n'
			}
		}
		mut by_lat := rows.filter(it.lat_ms > 0)
		by_lat.sort(a.lat_ms > b.lat_ms)
		if by_lat.len > 0 {
			b += 'Slowest:\n'
			for r in by_lat[..if by_lat.len < summary_top { by_lat.len } else { summary_top }] {
				b += ' ${link_line(r)}\n'
			}
		}
	}
	if s := last {
		b += if s.state == 'done' {
			'Last scan ${ago_text(now - s.finished)} ago: reached ${s.reached}/${s.repeaters}, ${s.replies}/${s.probes} probes answered'
		} else {
			'A scan is ${s.state}.'
		}
	}
	return b.trim_space()
}
