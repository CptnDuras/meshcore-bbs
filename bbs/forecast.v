module main

// Multi-day weather forecast via the US National Weather Service (no key).
// Buffalo, WY resolves to NWS gridpoint RIW/181,165 (obtained once via
// /points/44.348,-106.699 -> properties.forecast; hardcoded like wx.v pins
// station KBYG, so we avoid a second lookup on every call).
//
// Same FreeBSD constraints as wx.v: shell out to curl, parse the few fields we
// need by hand. Parsing is a pure function for offline unit testing.
const forecast_url = 'https://api.weather.gov/gridpoints/RIW/181,165/forecast'
const forecast_ua = 'meshbbs (steven.butler@gmail.com)'
const forecast_default_days = 3
const forecast_max_days = 7

// fetch_forecast returns a terse multi-period forecast. `days` is clamped to
// 1..7; each day is ~2 NWS periods (day + night), so we render up to days*2
// periods.
pub fn fetch_forecast(days int) string {
	body := curl_get(forecast_url, forecast_ua)
	return format_forecast(body, days)
}

// format_forecast builds the forecast text from an NWS forecast JSON body.
// Pure -> unit-testable with a fixture. days clamped 1..7; renders day*2 periods.
fn format_forecast(body string, days int) string {
	if body.len == 0 {
		return 'FORECAST: could not reach weather service'
	}
	mut d := days
	if d < 1 {
		d = forecast_default_days
	}
	if d > forecast_max_days {
		d = forecast_max_days
	}
	max_periods := d * 2
	periods := parse_forecast_periods(body, max_periods)
	if periods.len == 0 {
		return 'FORECAST: no data'
	}
	mut lines := []string{}
	lines << 'Forecast (Buffalo, WY):'
	for p in periods {
		lines << '${p.name}: ${p.temp}${p.unit}, ${p.short}'
	}
	return lines.join('\n')
}

struct ForecastPeriod {
	name  string
	temp  string
	unit  string
	short string
}

// parse_forecast_periods extracts up to `max` periods from the forecast body.
// NWS lists periods in order under "periods": [ {name,temperature,
// temperatureUnit,shortForecast}, ... ]. We walk sequential "name" keys and
// pull the sibling fields that follow each one.
fn parse_forecast_periods(body string, max int) []ForecastPeriod {
	mut out := []ForecastPeriod{}
	mut search_from := 0
	for out.len < max {
		nkey := body[search_from..].index('"name":') or { break }
		nstart := search_from + nkey
		name := extract_string(body[nstart..], 'name')
		// bound the period slice to the next "number" or end, so fields belong
		// to this period. Simpler: read temperature/unit/shortForecast that
		// appear after this name.
		rest := body[nstart + 7..]
		temp := extract_number_token(rest, 'temperature')
		unit := extract_string(rest, 'temperatureUnit')
		short := extract_string(rest, 'shortForecast')
		if name.len > 0 && temp.len > 0 {
			out << ForecastPeriod{
				name:  name
				temp:  temp
				unit:  unit
				short: short
			}
		}
		// advance past this name occurrence
		search_from = nstart + 7
	}
	return out
}

// extract_number_token finds "key": <number> and returns the integer token as
// a string (empty if absent). Distinct from wx.v's extract_value which expects
// a nested {"value": ...} object; forecast temps are bare integers.
fn extract_number_token(body string, key string) string {
	needle := '"${key}":'
	idx := body.index(needle) or { return '' }
	mut i := idx + needle.len
	for i < body.len && (body[i] == ` ` || body[i] == `\t`) {
		i++
	}
	mut tok := []u8{}
	for i < body.len {
		c := body[i]
		if (c >= `0` && c <= `9`) || c == `-` {
			tok << c
			i++
		} else {
			break
		}
	}
	return tok.bytestr()
}
