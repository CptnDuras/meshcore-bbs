module main

// Offline tests for the NWS multi-day forecast parser. Fixture mirrors the real
// api.weather.gov gridpoint forecast shape (periods array).
const fixture_forecast = '{"properties":{"periods":[' +
	'{"number":1,"name":"Today","temperature":77,"temperatureUnit":"F","shortForecast":"Mostly Sunny"},' +
	'{"number":2,"name":"Tonight","temperature":46,"temperatureUnit":"F","shortForecast":"Partly Cloudy"},' +
	'{"number":3,"name":"Saturday","temperature":71,"temperatureUnit":"F","shortForecast":"Mostly Sunny"},' +
	'{"number":4,"name":"Saturday Night","temperature":44,"temperatureUnit":"F","shortForecast":"Clear"},' +
	'{"number":5,"name":"Sunday","temperature":73,"temperatureUnit":"F","shortForecast":"Sunny"},' +
	'{"number":6,"name":"Sunday Night","temperature":45,"temperatureUnit":"F","shortForecast":"Clear"}' +
	']}}'

fn test_forecast_default_days() {
	// default 3 days -> up to 6 periods
	out := format_forecast(fixture_forecast, forecast_default_days)
	assert out.contains('Forecast (Buffalo, WY)')
	assert out.contains('Today: 77F, Mostly Sunny')
	assert out.contains('Tonight: 46F, Partly Cloudy')
	assert out.contains('Sunday Night: 45F, Clear')
}

fn test_forecast_one_day_two_periods() {
	out := format_forecast(fixture_forecast, 1)
	assert out.contains('Today: 77F')
	assert out.contains('Tonight: 46F')
	// day 2 should not appear
	assert !out.contains('Saturday:')
}

fn test_forecast_clamps_days() {
	// 99 days clamps to max (7) -> but fixture only has 6 periods; must not crash
	out := format_forecast(fixture_forecast, 99)
	assert out.contains('Today: 77F')
	assert out.contains('Sunday: 73F')
}

fn test_forecast_empty_body() {
	assert format_forecast('', 3).contains('could not reach')
}

fn test_extract_number_token_negative() {
	assert extract_number_token('"temperature": -12,', 'temperature') == '-12'
	assert extract_number_token('"temperature": 8}', 'temperature') == '8'
	assert extract_number_token('{}', 'temperature') == ''
}
