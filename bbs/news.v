module main

// Local news headlines via RSS (no key required). Same curl-shellout + manual
// parse approach as wx.v/spacewx.v (V http TLS + json2 crash on this FreeBSD).
// Parsing is pure (operates on a body string) so it is unit-testable offline.
//
// Sources (confirmed working feeds):
//   Sheridan Media (Buffalo-area):  category/news/feed/   (WordPress)
//   Buffalo Bulletin:               /search/?f=rss ...     (BLOX/TownNews)
const news_ua = 'meshbbs (steven.butler@gmail.com)'
const sheridan_feed = 'https://sheridanmedia.com/category/news/feed/'
const buffalo_feed = 'https://www.buffalobulletin.com/search/?f=rss&t=article&c[]=news/local_news&l=50&s=start_time&sd=desc'
const news_per_source = 3
const news_pool = 20 // extract a larger pool so aging can find fresh items

pub fn fetch_news() string {
	sheridan_body := curl_get(sheridan_feed, news_ua)
	buffalo_body := curl_get(buffalo_feed, news_ua)
	return format_news(sheridan_body, buffalo_body)
}

// fetch_news_fresh applies news aging: it pulls a larger pool from each feed,
// drops headlines already broadcast (per the store), records the ones it
// selects, and formats them. When nothing fresh remains it falls back to the
// latest headlines so a scheduled send is never blank.
fn (mut e Engine) fetch_news_fresh() string {
	sheridan_body := curl_get(sheridan_feed, news_ua)
	buffalo_body := curl_get(buffalo_feed, news_ua)
	if sheridan_body.len == 0 && buffalo_body.len == 0 {
		return 'NEWS: could not reach local feeds'
	}
	seen := e.store.seen_headlines()
	sher_all := extract_headlines(sheridan_body, news_pool)
	buff_all := extract_headlines(buffalo_body, news_pool)

	mut sher := filter_fresh(sher_all, seen, news_per_source)
	mut buff := filter_fresh(buff_all, seen, news_per_source)
	mut all_stale := false
	// fallback: if a source produced items but none are fresh, show its latest
	if sher.len == 0 && sher_all.len > 0 && buff.len == 0 && buff_all.len > 0 {
		all_stale = true
		sher = sher_all[..news_min(news_per_source, sher_all.len)]
		buff = buff_all[..news_min(news_per_source, buff_all.len)]
	}
	// record the selected headlines so they age out next time
	for h in sher {
		e.store.mark_headline_sent(h) or {}
	}
	for h in buff {
		e.store.mark_headline_sent(h) or {}
	}
	return build_news_report(sher, buff, all_stale)
}

fn news_min(a int, b int) int {
	return if a < b { a } else { b }
}

// filter_fresh returns up to `max` headlines from `all` that are not in `seen`,
// preserving order. Pure -> unit testable. If fewer than `max` are fresh, it
// returns just the fresh ones (caller decides on a stale fallback).
fn filter_fresh(all []string, seen map[string]bool, max int) []string {
	mut out := []string{}
	for h in all {
		if out.len >= max {
			break
		}
		if !seen[h] {
			out << h
		}
	}
	return out
}

// build_news_report formats the combined report from already-selected per-source
// headline lists. Pure. Empty overall -> a friendly 'no fresh news' note.
fn build_news_report(sheridan []string, buffalo []string, all_stale bool) string {
	if sheridan.len == 0 && buffalo.len == 0 {
		if all_stale {
			return '== Local News ==\nNo new headlines since last update.'
		}
		return 'NEWS: could not reach local feeds'
	}
	mut b := '== Local News ==\n'
	if sheridan.len > 0 {
		b += '[Sheridan Media]\n'
		for h in sheridan {
			b += '- ${h}\n'
		}
	}
	if buffalo.len > 0 {
		b += '[Buffalo Bulletin]\n'
		for h in buffalo {
			b += '- ${h}\n'
		}
	}
	return b.trim_right('\n')
}

// format_news builds the combined headline report from two RSS bodies.
// Pure function so it can be unit-tested with fixture strings.
fn format_news(sheridan_body string, buffalo_body string) string {
	sheridan := extract_headlines(sheridan_body, news_per_source)
	buffalo := extract_headlines(buffalo_body, news_per_source)

	if sheridan.len == 0 && buffalo.len == 0 {
		return 'NEWS: could not reach local feeds'
	}

	mut b := '== Local News ==\n'
	if sheridan.len > 0 {
		b += '[Sheridan Media]\n'
		for h in sheridan {
			b += '- ${h}\n'
		}
	}
	if buffalo.len > 0 {
		b += '[Buffalo Bulletin]\n'
		for h in buffalo {
			b += '- ${h}\n'
		}
	}
	return b.trim_right('\n')
}

// extract_headlines returns up to `max` item titles from an RSS body. Titles
// are read only from within <item>...</item> blocks, so the channel title and
// any <image><title> (which WordPress feeds include) are naturally excluded.
fn extract_headlines(body string, max int) []string {
	mut out := []string{}
	if body.len == 0 {
		return out
	}
	mut search_from := 0
	for out.len < max {
		// find the next <item> block
		item_rel := body[search_from..].index('<item>') or { break }
		item_start := search_from + item_rel + '<item>'.len
		item_end_rel := body[item_start..].index('</item>') or { break }
		item_end := item_start + item_end_rel
		item := body[item_start..item_end]
		search_from = item_end + '</item>'.len

		// pull the <title> from within this item
		trel := item.index('<title>') or { continue }
		tstart := trel + '<title>'.len
		tend_rel := item[tstart..].index('</title>') or { continue }
		raw := item[tstart..tstart + tend_rel]
		title := clean_title(raw)
		if title.len > 0 {
			out << title
		}
	}
	return out
}

// clean_title strips CDATA wrappers, decodes a few common HTML entities, and
// trims whitespace so a headline is readable on a tiny mesh screen.
fn clean_title(raw string) string {
	mut s := raw.trim_space()
	// strip <![CDATA[ ... ]]>
	if s.starts_with('<![CDATA[') {
		s = s['<![CDATA['.len..]
		if s.ends_with(']]>') {
			s = s[..s.len - ']]>'.len]
		}
	}
	s = decode_entities(s)
	return s.trim_space()
}

// decode_entities handles the small set of HTML entities that show up in these
// feeds' titles. We keep it minimal and dependency-free.
fn decode_entities(input string) string {
	mut s := input
	s = s.replace('&#8211;', '-') // en dash
	s = s.replace('&#8212;', '-') // em dash
	s = s.replace('&#8217;', "'") // right single quote
	s = s.replace('&#8216;', "'") // left single quote
	s = s.replace('&#8220;', '"') // left double quote
	s = s.replace('&#8221;', '"') // right double quote
	s = s.replace('&#038;', '&')
	s = s.replace('&amp;', '&')
	s = s.replace('&quot;', '"')
	s = s.replace('&apos;', "'")
	s = s.replace('&lt;', '<')
	s = s.replace('&gt;', '>')
	return s
}
