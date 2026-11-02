#!/usr/bin/env python3
# microphone-tracker.lua (Steam Frame image): guard against "no default source/sink yet". Without it WirePlumber
# segfaults (Json.Raw(nil) -> strlen(NULL)) when it starts before the sound card is ready, and systemd gives up.
import shutil, sys
p = sys.argv[1] if len(sys.argv) > 1 else "/etc/wireplumber/scripts/microphone-tracker.lua"
s = open(p).read()
old = ('  local default_source_name = Json.Raw(defaults:find(0, "default.audio.source")):parse().name\n'
       '  local default_sink_name = Json.Raw(defaults:find(0, "default.audio.sink")):parse().name\n')
new = ('  -- s15: no default source/sink yet (sound card not ready): wait for the next event\n'
       '  local default_source = defaults and defaults:find(0, "default.audio.source")\n'
       '  local default_sink = defaults and defaults:find(0, "default.audio.sink")\n'
       '  if not default_source or not default_sink then\n'
       '    return\n'
       '  end\n'
       '  local default_source_name = Json.Raw(default_source):parse().name\n'
       '  local default_sink_name = Json.Raw(default_sink):parse().name\n')
if "s15: no default source/sink" in s:
    print("already patched"); sys.exit(0)
assert s.count(old) == 1, "anchor not found"
shutil.copy2(p, p + ".frame")
open(p, "w").write(s.replace(old, new)); print("patched", p)
