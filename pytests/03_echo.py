#!/usr/bin/env python3
"""
Test 3: Echo bot — the core BBS loop, proven with the Python lib.

Listens for incoming direct messages and channel messages, and echoes them
back. This is the exact receive -> parse -> respond round trip the BBS is
built on. If this works, the whole chain (radio, firmware, protocol) is good,
and porting the loop to V is purely a coding exercise.

Send it a DM (or a channel message) from another MeshCore node/app and watch
it reply.

Usage:
    python 03_echo.py /dev/cuaU0
Ctrl-C to stop.
"""
import asyncio
import sys
from meshcore import MeshCore, EventType


async def main(port: str):
    mc = await MeshCore.create_serial(port, 115200)
    await mc.commands.send_appstart()
    print("Echo bot running. Send this node a message from another node. Ctrl-C to quit.\n")

    async def on_dm(event):
        data = event.payload
        sender = data.get("pubkey_prefix", "?")
        text = data.get("text", "")
        print(f"[DM] from {sender}: {text!r}")
        reply = f"you said: {text}"[:160]  # respect the 160-byte cap
        # send_msg accepts the sender's pubkey prefix/key as destination
        res = await mc.commands.send_msg(sender, reply)
        print(f"      -> replied ({res.type})")

    async def on_chan(event):
        data = event.payload
        ch = data.get("channel_idx")
        text = data.get("text", "")
        print(f"[CH {ch}] {text!r}  (not auto-replying to channel msgs)")

    mc.subscribe(EventType.CONTACT_MSG_RECV, on_dm)
    mc.subscribe(EventType.CHANNEL_MSG_RECV, on_chan)

    # Let the library pull messages from the radio queue automatically.
    await mc.start_auto_message_fetching()

    try:
        await asyncio.sleep(float("inf"))
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await mc.stop_auto_message_fetching()
        await mc.disconnect()
        print("\nStopped.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python 03_echo.py <serial-port>")
        sys.exit(1)
    try:
        asyncio.run(main(sys.argv[1]))
    except KeyboardInterrupt:
        pass
