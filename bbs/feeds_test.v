module main

// Offline tests for the space-weather and news parsers. These exercise the
// pure format/extract functions with fixture strings shaped like the real
// SWPC JSON and RSS feeds, so no network is touched.

// --- space weather ---

const fixture_kp = '[{"time_tag":"2026-09-10T12:00:00","Kp":2.33,"a_running":9},{"time_tag":"2026-09-10T15:00:00","Kp":5.67,"a_running":5}]'
const fixture_flux = '[{"time_tag":"2026-07-31T20:00:00","frequency":2800,"flux":1.480000000000000e+002},{"time_tag":"2026-07-31T21:00:00","frequency":2800,"flux":1.520000000000000e+002}]'
const fixture_scales = '{"0": {"DateStamp": "2026-09-10", "R": {"Scale": "0", "Text": "none"}, "S": {"Scale": "0", "Text": "none"}, "G": {"Scale": "1", "Text": "Minor"}}, "1": {"R": {"Scale": null, "Text": null}}}'

fn test_spacewx_kp_uses_latest() {
	// last Kp in the series is 5.67 -> "minor storm"
	out := format_spacewx(fixture_kp, '', '')
	assert out.contains('Kp 5.7')
	assert out.contains('minor storm')
}

fn test_spacewx_flux_scientific_notation() {
	// last flux 1.52e+002 -> 152
	out := format_spacewx('', fixture_flux, '')
	assert out.contains('SFI 152')
}

fn test_spacewx_scales_current_block() {
	// current (key "0") G is "Minor", R/S are "none"
	out := format_spacewx('', '', fixture_scales)
	assert out.contains('R:none')
	assert out.contains('S:none')
	assert out.contains('G:Minor')
}

fn test_spacewx_all_together() {
	out := format_spacewx(fixture_kp, fixture_flux, fixture_scales)
	assert out.starts_with('SPACEWX:')
	assert out.contains('Kp 5.7')
	assert out.contains('SFI 152')
	assert out.contains('G:Minor')
}

fn test_spacewx_all_empty() {
	out := format_spacewx('', '', '')
	assert out.contains('could not reach')
}

fn test_kp_word_thresholds() {
	assert kp_word(1.0) == 'quiet'
	assert kp_word(4.5) == 'unsettled'
	assert kp_word(5.5) == 'minor storm'
	assert kp_word(6.5) == 'moderate storm'
	assert kp_word(8.0) == 'strong+ storm'
}

// --- news ---

const fixture_sheridan = '<rss><channel><title>News &#8211; Sheridan Media</title>' +
	'<item><title>Final Plat Consideration</title><link>x</link></item>' +
	'<item><title>Sheridan VA to Host Town Hall</title><link>y</link></item>' +
	'<item><title>Drought Driving Bears &amp; Deer</title><link>z</link></item>' +
	'<item><title>Fourth Story</title></item></channel></rss>'

const fixture_buffalo = '<rss><channel><title>Buffalo Bulletin Local News</title>' +
	'<item><title>Johnson County land use plan raises questions</title></item>' +
	'<item><title>Game and Fish funding proposals advance</title></item></channel></rss>'

fn test_news_skips_channel_title() {
	hs := extract_headlines(fixture_sheridan, 3)
	// channel title must not appear
	for h in hs {
		assert !h.contains('Sheridan Media')
	}
	assert hs.len == 3
	assert hs[0] == 'Final Plat Consideration'
}

fn test_news_decodes_entities() {
	hs := extract_headlines(fixture_sheridan, 3)
	assert hs[2] == 'Drought Driving Bears & Deer'
}

fn test_news_respects_max() {
	hs := extract_headlines(fixture_sheridan, 2)
	assert hs.len == 2
}

fn test_news_format_combines_sources() {
	out := format_news(fixture_sheridan, fixture_buffalo)
	assert out.contains('Sheridan Media')
	assert out.contains('Buffalo Bulletin')
	assert out.contains('Final Plat Consideration')
	assert out.contains('Johnson County land use plan raises questions')
}

fn test_news_format_one_source_down() {
	out := format_news('', fixture_buffalo)
	assert out.contains('Buffalo Bulletin')
	assert out.contains('Johnson County land use plan raises questions')
	assert !out.contains('[Sheridan Media]')
}

fn test_news_both_down() {
	out := format_news('', '')
	assert out.contains('could not reach')
}

fn test_clean_title_cdata() {
	assert clean_title('<![CDATA[Hello World]]>') == 'Hello World'
}
