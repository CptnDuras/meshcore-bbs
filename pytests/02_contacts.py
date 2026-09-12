#!/usr/bin/env python3
"""
Test 2: Contacts + advert. Verifies the node can see the mesh and transmit.

- Lists known contacts (other nodes it has heard).
- Sends a flood advert so nearby nodes learn about this node.

Usage:
    python 02_contacts.py /dev/cuaU0
"""
import asyncio
import sys
from meshcore import MeshCore, EventType


async def main(port: str):
    mc = await MeshCore.create_serial(port, 115200)
    await mc.commands.send_appstart()

    print("=== CONTACTS ===")
    res = await mc.commands.get_contacts()
    if res.type == EventType.ERROR:
        print(f"get_contacts error: {res.payload}")
    else:
        contacts = res.payload
        if not contacts:
            print("  (no contacts yet — node hasn't heard others, or none nearby)")
        for key, c in contacts.items():
            name = c.get("adv_name", "?")
            print(f"  {name:20s}  pubkey={key[:12]}...  type={c.get('type')}")

    print("\nSending a flood advert so others can hear us ...")
    res = await mc.commands.send_advert(flood=True)
    print(f"  advert result: {res.type}")

    await mc.disconnect()
    print("Done.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python 02_contacts.py <serial-port>")
        sys.exit(1)
    asyncio.run(main(sys.argv[1]))
