#!/usr/bin/env python3
"""
Test 1: Connect to the MeshCore Companion node and print its self-info.
This is the 'prove the radio talks back' spike, using the official Python lib.

Usage:
    python 01_selfinfo.py /dev/cuaU0        # FreeBSD
    python 01_selfinfo.py /dev/ttyUSB0      # Linux
"""
import asyncio
import sys
from meshcore import MeshCore, EventType


async def main(port: str):
    print(f"Connecting to {port} ...")
    # debug=True prints the raw companion-protocol frames — great for seeing
    # the '<'/'>' framing we care about for the V port later.
    mc = await MeshCore.create_serial(port, 115200, debug=True)
    print("Connected.")

    # send_appstart() -> SELF_INFO (this is CMD_APP_START / RESP_CODE_SELF_INFO)
    res = await mc.commands.send_appstart()
    if res.type == EventType.ERROR:
        print(f"appstart error: {res.payload}")
    else:
        print("\n=== SELF_INFO ===")
        for k, v in res.payload.items():
            print(f"  {k}: {v}")

    # send_device_query() -> DEVICE_INFO (CMD_DEVICE_QUERY / RESP_CODE_DEVICE_INFO)
    res = await mc.commands.send_device_query()
    if res.type == EventType.ERROR:
        print(f"device_query error: {res.payload}")
    else:
        print("\n=== DEVICE_INFO ===")
        for k, v in res.payload.items():
            print(f"  {k}: {v}")

    await mc.disconnect()
    print("\nDone.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python 01_selfinfo.py <serial-port>")
        print("  FreeBSD: /dev/cuaU0   Linux: /dev/ttyUSB0")
        sys.exit(1)
    asyncio.run(main(sys.argv[1]))
