module main

fn test_trace_wait_follows_the_radios_estimate_within_bounds() {
	assert trace_wait_ms(0) == 3000 // never shorter than the floor
	assert trace_wait_ms(5000) == 6500
	assert trace_wait_ms(100000) == 30000 // nor longer than the ceiling
	assert trace_wait_ms(29000) == 30000
}
