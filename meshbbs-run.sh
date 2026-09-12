#!/bin/sh
#
# meshbbs-run - reset the USB radio, then exec the meshbbs daemon.
#
# daemon(8) supervises this script with -r, so it runs on every (re)start.
# Resetting the CP210x USB-serial bridge first clears a wedged radio that
# otherwise fails the appstart handshake (timeout waiting for SELF_INFO).
#
# Args: <serial_port> <db_cfg>  (passed straight through to meshbbs)
#
# Env overrides:
#   MESHBBS_BIN        path to the meshbbs binary
#   MESHBBS_USB_MATCH  grep pattern to find the radio in `usbconfig`
#   MESHBBS_PORT_NODE  device node to wait for after reset
#   MESHBBS_RESET      set to "no" to skip the USB reset

set -u

# rc.subr starts the child with a minimal PATH that omits /usr/local/bin
# (where sudo lives) and /usr/sbin (usbconfig). Ensure both are reachable.
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:${PATH:-}"
export PATH

MESHBBS_BIN="${MESHBBS_BIN:-/home/steve/projects/meshbbs/meshbbs}"
MESHBBS_USB_MATCH="${MESHBBS_USB_MATCH:-CP210|Silicon Labs}"
MESHBBS_PORT_NODE="${MESHBBS_PORT_NODE:-/dev/cuaU0}"
MESHBBS_RESET="${MESHBBS_RESET:-yes}"

port="${1:-/dev/cuaU0}"
db="${2:-sqlite:meshbbs.db}"

reset_radio() {
    # usbconfig requires root. When run under the service the whole child
    # runs as the service user, so use sudo (a passwordless rule is expected;
    # see the .rc header). If sudo/usbconfig is unavailable, skip gracefully.
    _uc="$(command -v usbconfig || true)"
    [ -n "${_uc}" ] || [ ! -x /usr/sbin/usbconfig ] || _uc=/usr/sbin/usbconfig
    [ -n "${_uc}" ] || { echo "meshbbs-run: usbconfig not found, skipping reset"; return 0; }

    _sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        _sudo="$(command -v sudo || true)"
        [ -n "${_sudo}" ] || [ ! -x /usr/local/bin/sudo ] || _sudo=/usr/local/bin/sudo
        [ -n "${_sudo}" ] || { echo "meshbbs-run: not root and no sudo, skipping reset"; return 0; }
    fi

    _dev="$(${_sudo} ${_uc} 2>/dev/null | grep -iE "${MESHBBS_USB_MATCH}" | head -1 | cut -d: -f1)"
    if [ -z "${_dev}" ]; then
        echo "meshbbs-run: radio not found in usbconfig (match='${MESHBBS_USB_MATCH}'), skipping reset"
        return 0
    fi

    echo "meshbbs-run: resetting USB radio ${_dev} ..."
    ${_sudo} ${_uc} -d "${_dev}" reset 2>&1 || echo "meshbbs-run: reset returned non-zero (continuing)"

    # Wait for the device node to re-enumerate (up to ~10s).
    _i=0
    while [ ! -c "${MESHBBS_PORT_NODE}" ] && [ "${_i}" -lt 20 ]; do
        sleep 0.5
        _i=$((_i + 1))
    done
    # Small settle delay after the node reappears.
    sleep 2
    echo "meshbbs-run: radio ready (${MESHBBS_PORT_NODE})"
}

if [ "${MESHBBS_RESET}" = "yes" ]; then
    reset_radio
fi

exec "${MESHBBS_BIN}" "${port}" "${db}"
