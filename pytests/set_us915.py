import asyncio, sys
from meshcore import MeshCore, EventType

async def main(port):
    mc = await MeshCore.create_serial(port, 115200)
    if not mc:
        print("connect failed"); return
    await asyncio.sleep(1.0)          # settle after any DTR reset
    r = await mc.commands.send_appstart()
    if r.type == EventType.ERROR:
        print("appstart error:", r.payload); await mc.disconnect(); return
    p = r.payload
    print(f"BEFORE: freq={p['radio_freq']} bw={p['radio_bw']} sf={p['radio_sf']} cr={p['radio_cr']} name={p['name']}")

    res = await mc.commands.set_radio(910.525, 62.5, 7, 5)
    print("set_radio ->", res.type, getattr(res, "payload", None))
    await asyncio.sleep(0.5)

    r = await mc.commands.send_appstart()
    if r.type != EventType.ERROR:
        p = r.payload
        print(f"AFTER:  freq={p['radio_freq']} bw={p['radio_bw']} sf={p['radio_sf']} cr={p['radio_cr']}")
    await mc.disconnect()

asyncio.run(main(sys.argv[1]))
