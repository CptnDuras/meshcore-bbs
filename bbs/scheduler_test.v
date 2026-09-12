module main

fn noop_produce() string {
	return 'x'
}

// --- interval jobs ---

fn test_interval_never_run_is_due() {
	j := Job{
		name:          'i'
		kind:          .interval
		interval_secs: 60
		last_run:      0
		produce:       noop_produce
	}
	assert job_due(j, 1000, 0) == true
}

fn test_interval_not_due_within_window() {
	j := Job{
		name:          'i'
		kind:          .interval
		interval_secs: 60
		last_run:      1000
		produce:       noop_produce
	}
	assert job_due(j, 1030, minute_of_day(1030)) == false
}

fn test_interval_due_after_window() {
	j := Job{
		name:          'i'
		kind:          .interval
		interval_secs: 60
		last_run:      1000
		produce:       noop_produce
	}
	assert job_due(j, 1060, minute_of_day(1060)) == true
}

// --- daily jobs ---

fn test_daily_due_at_matching_minute() {
	// 08:00 local = 480 minutes past midnight
	j := Job{
		name:         'd'
		kind:         .daily
		daily_minute: 480
		last_run:     0
		produce:      noop_produce
	}
	// pick an epoch whose minute-of-day is 480
	now := i64(480 * 60) // 08:00 on day 0 (UTC)
	assert minute_of_day(now) == 480
	assert job_due(j, now, minute_of_day(now)) == true
}

fn test_daily_not_due_at_other_minute() {
	j := Job{
		name:         'd'
		kind:         .daily
		daily_minute: 480
		last_run:     0
		produce:      noop_produce
	}
	now := i64(481 * 60) // 08:01
	assert job_due(j, now, minute_of_day(now)) == false
}

fn test_daily_only_once_per_day() {
	now := i64(480 * 60)
	j := Job{
		name:         'd'
		kind:         .daily
		daily_minute: 480
		last_run:     now // already ran this minute
		produce:      noop_produce
	}
	assert job_due(j, now, minute_of_day(now)) == false
}

// --- tick ---

fn test_tick_runs_due_jobs_and_marks_last_run() {
	mut s := Scheduler{}
	s.add(Job{
		name:          'a'
		kind:          .interval
		interval_secs: 10
		produce:       fn () string {
			return 'hello'
		}
	})
	out := s.tick(1000, 0)
	assert out.len == 1
	assert out[0] == 'hello'
	// immediately ticking again should not re-run (within interval)
	out2 := s.tick(1005, 0)
	assert out2.len == 0
}

fn test_tick_skips_empty_producer() {
	mut s := Scheduler{}
	s.add(Job{
		name:          'empty'
		kind:          .interval
		interval_secs: 10
		produce:       fn () string {
			return '' // e.g. data source unavailable -> skip broadcast
		}
	})
	out := s.tick(1000, 0)
	assert out.len == 0
}

fn test_tick_tz_offset_applied() {
	// job at local minute 60 (01:00 local). With now=0 (00:00 UTC) and a
	// +3600s tz offset, local becomes 01:00 -> minute_of_day 60 -> due.
	mut s := Scheduler{}
	s.add(Job{
		name:         'tz'
		kind:         .daily
		daily_minute: 60
		produce:      noop_produce
	})
	out := s.tick(0, 3600)
	assert out.len == 1
}
