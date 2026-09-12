import asyncio, sys
from meshcore import MeshCore, EventType

async def main(port):
    mc = await MeshCore.create_serial(port, 115200)
    if not mc:
        print("connect failed"); return
    await asyncio.sleep(2.0)  # settle after DTR reset
    r = await mc.commands.send_appstart()
    if r.type == EventType.ERROR:
        print("appstart error:", r.payload); await mc.disconnect(); return
    print("connected:", r.payload.get("name"), r.payload.get("radio_freq"), "MHz")

    print("\n=== draining pending messages ===")
    for i in range(20):
        m = await mc.commands.get_msg()
        if m.type == EventType.NO_MORE_MSGS:
            print("  no more messages" if i == 0 else f"  drained {i} message(s)")
            break
        print(f"  msg[{i}] {m.type}: {m.payload}")
    else:
        print("  (stopped after 20)")

    print("\n=== current channels ===")
    for idx in (0, 1, 2):
        c = await mc.commands.get_channel(idx)
        print(f"  ch{idx}: {c.type} {getattr(c,'payload',None)}")

    await mc.disconnect()

asyncio.run(main(sys.argv[1]))
