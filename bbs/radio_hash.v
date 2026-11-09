module main

import meshcore

// The radio puts a few bytes of each repeater's key into the path of every packet it sends. More bytes tell repeaters apart better, so this node
// uses 2 byte names (mode 1; the modes are 0, 1 and 2 for 1, 2 and 3 bytes).

const wanted_path_hash_mode = 1

// path_hash_mode_to_set says which mode to switch the radio to, or none when it already has the wanted one or the firmware does not say (-1).
pub fn path_hash_mode_to_set(current int) ?u8 {
	if current < 0 || current == wanted_path_hash_mode {
		return none
	}
	return u8(wanted_path_hash_mode)
}

// ensure_path_hash_mode reads the radio's setting and changes it if it is not the wanted one. The firmware keeps the setting across restarts, so
// this is a no-op after the first run. It returns a line to log.
pub fn ensure_path_hash_mode(mut mc meshcore.MeshCore) string {
	info := mc.send_device_query() or { return 'path hash mode: could not read the radio (${err})' }
	current := info.payload.path_hash_mode
	mode := path_hash_mode_to_set(current) or {
		return if current < 0 {
			'path hash mode: this firmware does not report it, left alone'
		} else {
			'path hash mode: already ${current + 1} byte names'
		}
	}
	mc.set_path_hash_mode(mode) or { return 'path hash mode: could not set ${mode + 1} byte names (${err})' }
	return 'path hash mode: changed from ${current + 1} to ${mode + 1} byte names'
}
