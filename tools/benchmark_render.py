#!/usr/bin/env python3
"""Compare the old disk-stamping renderer with current span rendering.

Developer benchmark only: install lupa with python -m pip install lupa.
Timings measure Lua computation with a counting fake BlitBuffer, not Kindle
display latency. Native paintRect call counts indicate work avoided at FFI.
"""

import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCAL_DEPS = ROOT / ".research" / "test-runtime"
if LOCAL_DEPS.exists():
    sys.path.insert(0, str(LOCAL_DEPS))

try:
    from lupa.luajit21 import LuaRuntime
except ImportError:
    from lupa.lua51 import LuaRuntime

OLD_RENDERER = r"""
function old_line(bb, a, b, width, color, clip)
    local radius = math.max(1, math.floor(width/2+0.5))
    local dx,dy = b.x-a.x,b.y-a.y
    local steps = math.max(1, math.ceil(math.sqrt(dx*dx+dy*dy)/math.max(1,radius*0.65)))
    for i=0,steps do
        local x,y = math.floor(a.x+dx*i/steps+0.5),math.floor(a.y+dy*i/steps+0.5)
        for row=-radius,radius do
            local py = y+row
            if py >= clip.y and py < clip.y+clip.h then
                local half = math.floor(math.sqrt(radius*radius-row*row))
                local left = math.max(clip.x,x-half)
                local right = math.min(clip.x+clip.w-1,x+half)
                if right >= left then bb:paintRect(left,py,right-left+1,1,color) end
            end
        end
    end
end

function measure(renderer, scene, repeats)
    local bb = {calls=0,paintRect=function(self) self.calls=self.calls+1 end}
    local clip = {x=0,y=0,w=1860,h=2480}
    -- Warm LuaJIT before the timed run.
    for i=1,100 do
        for _,s in ipairs(scene) do renderer(bb,s[1],s[2],s[3],0,clip) end
    end
    bb.calls = 0
    collectgarbage('collect')
    local started = os.clock()
    for i=1,repeats do
        for _,s in ipairs(scene) do renderer(bb,s[1],s[2],s[3],0,clip) end
    end
    return os.clock()-started,bb.calls
end
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repeat", type=int, default=3000)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(OLD_RENDERER)
    renderer = lua.execute((ROOT / "scribeink.koplugin" / "render.lua").read_text(encoding="utf-8"))
    scenes = {
        "Handwriting samples": lua.eval("{{{x=200,y=210},{x=210,y=214},4},"
                                        "{{x=210,y=214},{x=218,y=224},4},"
                                        "{{x=218,y=224},{x=215,y=237},4},"
                                        "{{x=215,y=237},{x=205,y=232},4}}"),
        "Long strokes": lua.eval("{{{x=100,y=600},{x=1100,y=600},4},"
                                 "{{x=100,y=600},{x=100,y=1600},4},"
                                 "{{x=100,y=600},{x=1100,y=1000},4}}"),
    }
    for label, scene in scenes.items():
        before, before_calls = lua.globals().measure(lua.globals().old_line, scene, args.repeat)
        after, after_calls = lua.globals().measure(renderer.line, scene, args.repeat)
        print(f"{label}: paintRect calls {before_calls:,} -> {after_calls:,} "
              f"({before_calls / after_calls:.1f}x fewer); Lua CPU {before:.4f}s -> {after:.4f}s")


if __name__ == "__main__":
    main()
