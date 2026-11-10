-- probe_autopress.lua —— 真机探针（machine script，用 -autoboot_script 加载）
-- 目的：验证插件的 set_value 是否真的影响了「最终输入值」（避坑指南 §3.7：
--       type_pressed 看不见 set_value，port:read() 才是最终值）。
-- 用法：mameui xmen -autoboot_script probe_autopress.lua ... -log -verbose

local targets = {}
local frame = 0
local DUMP_LIMIT = 60

emu.register_start(function()
	local ioport = manager.machine.ioport
	local dumped = 0
	for tag, port in pairs(ioport.ports) do
		local fields = port.fields
		if fields and dumped < DUMP_LIMIT then
			print(string.format('[probe] port %s', tostring(tag)))
			for key, f in pairs(fields) do
				local ty = nil
				pcall(function() ty = f.type end)
				print(string.format('[probe]   field "%s" type=%s', tostring(key), tostring(ty)))
				dumped = dumped + 1
				local nm = tostring(key)
				if nm == 'P1_JOYSTICK_RIGHT' or nm == 'P1 Button 1'
					or nm == 'P1_JOYSTICK_UP' or nm == 'P2 Button 1' then
					targets[#targets + 1] = { name = nm, field = f }
				end
			end
		end
	end
	print(string.format('[probe] targets=%d', #targets))
end)

emu.register_frame_done(function()
	frame = frame + 1
	if #targets == 0 then return end
	if frame % 5 ~= 0 then return end
	local parts = {}
	for _, t in ipairs(targets) do
		local ok, v = pcall(function() return t.field:read() end)
		if not ok then v = 'ERR' end
		parts[#parts + 1] = string.format('%s=%s', t.name, tostring(v))
	end
	print(string.format('[probe] f=%d %s', frame, table.concat(parts, ' ')))
end)
