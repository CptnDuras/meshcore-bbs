module main

import rand

// DB-backed scheduled-message evaluation. The daemon calls scheduled_due() for
// each enabled ScheduledMessage every loop tick; when due it enqueues an
// OutboundMessage and marks last_run (one-time schedules are then disabled).
//
// The decision is a pure function so it is unit-testable with an injected clock
// (mirrors scheduler.v's job_due). minute_of_day() is reused from scheduler.v.

// scheduled_due reports whether a schedule should fire at `now` (epoch secs),
// given the local minute-of-day for `now`.
//   onetime  -> due when enabled, not yet run, and now >= run_at
//   interval -> due when now - last_run >= interval_secs (or never run)
//   daily    -> due when local minute == daily_minute and not already run in
//               the last ~23h
fn scheduled_due(m ScheduledMessage, now i64, minute_of_day int) bool {
	if !m.enabled {
		return false
	}
	match m.sched_kind {
		sched_onetime {
			if m.last_run > 0 {
				return false // already fired
			}
			return m.run_at > 0 && now >= m.run_at
		}
		sched_interval {
			if m.interval_secs <= 0 {
				return false
			}
			if m.last_run <= 0 {
				return true
			}
			return (now - m.last_run) >= m.interval_secs
		}
		sched_daily {
			if minute_of_day != m.daily_minute {
				return false
			}
			if m.last_run > 0 && (now - m.last_run) < (23 * 60 * 60) {
				return false
			}
			return true
		}
		else {
			return false
		}
	}
}

// onetime schedules should be disabled after they fire so they never repeat.
fn scheduled_is_onetime(m ScheduledMessage) bool {
	return m.sched_kind == sched_onetime
}

// resolve_source produces the text to send for a due schedule. For 'static' it
// returns the row's own text; for the dynamic sources it generates fresh
// content at send time (live weather/news/fortune). It is an Engine method so
// news aging can consult/record the sent-headline set in the store.
fn (mut e Engine) resolve_source(source string, static_text string) string {
	return match source {
		src_wx {
			fetch_weather()
		}
		src_spacewx {
			fetch_spacewx()
		}
		src_news {
			e.fetch_news_fresh()
		}
		src_forecast {
			fetch_forecast(forecast_default_days)
		}
		src_fortune {
			list := load_fortunes()
			if list.len == 0 {
				''
			} else {
				'Fortune: ' + list[rand_index(list.len)]
			}
		}
		src_digest {
			// morning digest: weather + 5-day forecast + space weather + fresh news
			'${fetch_weather()}\n${fetch_forecast(5)}\n${fetch_spacewx()}\n${e.fetch_news_fresh()}'
		}
		else {
			static_text // src_static and any unknown value
		}
	}
}

// rand_index returns a random index in [0, n). Safe for n<=0.
fn rand_index(n int) int {
	if n <= 0 {
		return 0
	}
	return rand.intn(n) or { 0 }
}
