module main

// Scheduler — a tiny cron-like primitive for proactive broadcasts.
//
// This is the enabling piece behind "automated bits besides messaging": the
// main loop ticks the scheduler once per second; any due Job's producer is
// called to build a message, which the loop broadcasts to public channel 0.
//
// Two scheduling modes:
//   - interval jobs: run every `interval_secs` seconds
//   - daily jobs:    run once per day at `daily_minute` (minutes past local
//                    midnight, 0..1439)
//
// The "is it due?" decision is a pure function (job_due) tested with an
// injected clock; the Scheduler struct just holds state and bookkeeping.

// JobKind selects the scheduling mode.
pub enum JobKind {
	interval
	daily
}

// Job is a single scheduled task. `produce` returns the text to broadcast (or
// an empty string to skip this run, e.g. when a data source is unavailable).
pub struct Job {
pub mut:
	name         string
	kind         JobKind
	interval_secs i64    // for JobKind.interval
	daily_minute  int    // for JobKind.daily: minutes past midnight (0..1439)
	last_run      i64    // epoch secs of last run (0 = never)
	produce       fn () string @[required]
}

// Scheduler owns a set of jobs.
pub struct Scheduler {
pub mut:
	jobs []Job
}

// add registers a job.
pub fn (mut s Scheduler) add(j Job) {
	s.jobs << j
}

// job_due decides whether a job should run at `now` (epoch secs), given the
// local minute-of-day for `now`. Pure -> unit testable.
//   interval: due when now - last_run >= interval_secs (or never run).
//   daily:    due when the current local minute-of-day matches daily_minute
//             and it hasn't already run within the last ~23h.
fn job_due(j Job, now i64, minute_of_day int) bool {
	match j.kind {
		.interval {
			if j.interval_secs <= 0 {
				return false
			}
			if j.last_run <= 0 {
				return true
			}
			return (now - j.last_run) >= j.interval_secs
		}
		.daily {
			if minute_of_day != j.daily_minute {
				return false
			}
			// Only once per day: skip if we already ran within the last 23h.
			if j.last_run > 0 && (now - j.last_run) < (23 * 60 * 60) {
				return false
			}
			return true
		}
	}
}

// minute_of_day returns local minutes past midnight for an epoch time.
fn minute_of_day(now i64) int {
	secs_into_day := int(now % 86400)
	return secs_into_day / 60
}

// tick runs all due jobs at time `now`, returning the list of texts to
// broadcast (non-empty producer outputs only). Marks run jobs' last_run.
// `tz_offset_secs` shifts UTC epoch to local time for daily scheduling.
pub fn (mut s Scheduler) tick(now i64, tz_offset_secs i64) []string {
	local := now + tz_offset_secs
	mod := minute_of_day(local)
	mut out := []string{}
	for i in 0 .. s.jobs.len {
		if job_due(s.jobs[i], now, mod) {
			s.jobs[i].last_run = now
			text := s.jobs[i].produce()
			if text.len > 0 {
				out << text
			}
		}
	}
	return out
}
