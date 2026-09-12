module main

// Offline tests for the NWS weather parser (wx.v). Fixtures mirror the real
// api.weather.gov ld+json observation shape captured from station KBYG, so no
// network is touched.

// A realistic observation body: textDescription + nested measurement objects,
// each with a "value" field (matching the live API structure).
const fixture_wx = '{
	"@context": { "value": { "@id": "s:value" } },
	"textDescription": "Clear",
	"temperature": { "unitCode": "wmoUnit:degC", "value": 29, "qualityControl": "V" },
	"windSpeed": { "unitCode": "wmoUnit:km_h-1", "value": 11.124, "qualityControl": "V" },
	"relativeHumidity": { "unitCode": "wmoUnit:percent", "value": 10.549722650781, "qualityControl": "V" }
}'

// A body where a measurement is explicitly null (NWS does this).
const fixture_wx_null_temp = '{
	"textDescription": "Foggy",
	"temperature": { "unitCode": "wmoUnit:degC", "value": null, "qualityControl": "Z" },
	"windSpeed": { "unitCode": "wmoUnit:km_h-1", "value": 0, "qualityControl": "V" }
}'

// --- extract_string ---

fn test_extract_string_finds_value() {
	assert extract_string(fixture_wx, 'textDescription') == 'Clear'
}

fn test_extract_string_missing_key() {
	assert extract_string(fixture_wx, 'noSuchKey') == ''
}

// --- extract_value ---

fn test_extract_value_temperature() {
	v := extract_value(fixture_wx, 'temperature') or { panic('temperature should parse') }
	assert v == 29.0
}

fn test_extract_value_float() {
	v := extract_value(fixture_wx, 'windSpeed') or { panic('windSpeed should parse') }
	// 11.124 within float tolerance
	assert v > 11.1 && v < 11.2
}

fn test_extract_value_null_returns_none() {
	if _ := extract_value(fixture_wx_null_temp, 'temperature') {
		assert false, 'null value must return none'
	}
	assert true
}

fn test_extract_value_missing_key() {
	if _ := extract_value(fixture_wx, 'noSuchKey') {
		assert false, 'missing key must return none'
	}
	assert true
}

// --- format_weather (pure end-to-end) ---

fn test_format_weather_full() {
	out := format_weather(fixture_wx)
	assert out.starts_with('WX ')
	assert out.contains('Clear')
	// 29C -> 84F
	assert out.contains('84F (29C)')
	// 11.124 km/h -> ~6.9 -> "7mph"
	assert out.contains('wind 7mph')
	// 10.55% -> "11%"
	assert out.contains('hum 11%')
}

fn test_format_weather_partial_with_null() {
	out := format_weather(fixture_wx_null_temp)
	assert out.contains('Foggy')
	// temperature was null, so no F/C segment
	assert !out.contains('F (')
	// windSpeed 0 -> wind 0mph
	assert out.contains('wind 0mph')
}

fn test_format_weather_empty_body() {
	out := format_weather('')
	assert out.contains('no current data')
}
