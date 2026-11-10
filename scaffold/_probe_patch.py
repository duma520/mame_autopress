"""临时给部署侧 init.lua 插入只读探针（验证 field:read() 是否反映 set_value）。
用法：python scaffold/_probe_patch.py patch|restore
"""
import shutil
import sys
from pathlib import Path

SRC = Path(r"G:\Python_Code\mame_autopress\plugins\mame_autopress\init.lua")
DST = Path(r"Z:\ROM 街机\MAMEUI64 Plus!\mameui\plugins\mame_autopress\init.lua")
BAK = SRC.with_suffix(".lua.probe_bak")

PROBE = """
	-- TEMP PROBE BEGIN
	if frame_no % 5 == 0 then
		for tag, port in pairs(ioport.ports) do
			local okr, pv = pcall(function() return port:read() end)
			if okr then
				for key, f in pairs(port.fields) do
					local nm = tostring(key)
					if nm == 'P1 Right' or nm == 'P1 Button 1' then
						local mask = safe(function() return f.mask end, nil)
						local on = nil
						if mask and mask > 0 then
							on = ((pv % (mask * 2)) >= mask)
						end
						emu.print_info(string.format('[probe] f=%d %s pv=%s mask=%s on=%s',
							frame_no, nm, tostring(pv), tostring(mask), tostring(on)))
					end
				end
			end
		end
	end
	-- TEMP PROBE END
"""

MARKER = "local function tick()\n\tframe_no = frame_no + 1\n"


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "patch"
    if action == "patch":
        src = SRC.read_text(encoding="utf-8")
        if src.count(MARKER) != 1:
            print(f"FAIL: tick 标记命中 {src.count(MARKER)} 次，拒绝修改")
            return 1
        if "TEMP PROBE BEGIN" in src:
            print("已是探针版，跳过")
        else:
            src = src.replace(MARKER, MARKER + PROBE)
        DST.write_text(src, encoding="utf-8", newline="\n")
        print(f"探针版已写入 {DST}（{len(src.encode('utf-8'))} 字节）")
    elif action == "restore":
        shutil.copyfile(SRC, DST)
        raw = DST.read_bytes()
        assert not raw.startswith(b"\xef\xbb\xbf"), "恢复后仍带 BOM"
        print(f"已恢复正式版 {DST}（{len(raw)} 字节，无 BOM）")
    else:
        print("用法: patch|restore")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
