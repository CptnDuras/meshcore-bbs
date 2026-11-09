module main

fn test_path_hash_mode_to_set() {
	assert path_hash_mode_to_set(0)? == u8(1) // 1 byte names: switch to 2
	assert path_hash_mode_to_set(2)? == u8(1) // 3 byte names: also switch to 2
	if _ := path_hash_mode_to_set(1) {
		assert false // already 2 bytes: nothing to do
	}
	if _ := path_hash_mode_to_set(-1) {
		assert false // the firmware does not say: leave it alone
	}
}
