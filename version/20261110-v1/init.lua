-- license:BSD-3-Clause
-- mame_autopress —— 自动按键插件（每个玩家独立开关方向与按键）
--
-- 行为：把某项切到 ON 后，每帧对该输入字段做程序化写入：
--   mode='burst'（连发）：on_frames 帧按下、off_frames 帧松开，循环；
--   mode='hold' （持续）：每帧保持按下。
--   切到 OFF 时 clear_value() 把字段交还物理输入。
--
-- 显示：只列出「真实存在且已绑定按键」的字段；无绑定的不显示。
--
-- 依据《MAME插件开发避坑指南》（G:\Python_Code\mame_kbd\MAME插件开发避坑指南.md）：
--   §2.2 动作表必须 actions[#list]；§2.3 处理 back 出栈（双保险）；
--   §3.7 type_pressed 看不见 set_value，本插件只写不读；
--   §3.8 set_value 必须每帧持续写；§3.5 field.player 不可靠，玩家号从字段名解析；
--   §5.5 配置存 <homepath>/mame_autopress/；§8.8 frame 订阅必须持有引用。

local exports = {
		name = 'mame_autopress',
		version = '1.0.0',
		description = 'Auto-press: per-player toggles for 4 directions and assigned buttons',
		license = 'BSD-3-Clause',
		author = { name = 'local' } }
local mame_autopress = exports

-- 订阅对象必须持有引用，否则被 GC（指南 §8.8）
local frame_subscription, prestart_subscription, stop_subscription

-- ---------- 常量 ----------
-- MAME 输入类型枚举（与官方 IPT_ 一致）
local IPT = {
	UP = 47, DOWN = 48, LEFT = 49, RIGHT = 50,
	BUTTON1 = 60, BUTTON2 = 61, BUTTON3 = 62, BUTTON4 = 63,
	BUTTON5 = 64, BUTTON6 = 65, BUTTON7 = 66, BUTTON8 = 67,
	BUTTON9 = 68, BUTTON10 = 69, BUTTON11 = 70, BUTTON12 = 71,
	BUTTON13 = 72, BUTTON14 = 73, BUTTON15 = 74, BUTTON16 = 75,
}
local DIR_ORDER = { 'UP', 'DOWN', 'LEFT', 'RIGHT' }
local DIR_LABEL = { UP = '上', DOWN = '下', LEFT = '左', RIGHT = '右' }
local MAX_BUTTONS = 16
local PAGE_MAIN = 0
local FRAMES_MIN, FRAMES_MAX = 1, 30

-- 语义键白名单（持久化时校验，避免把垃圾写进设置）
local VALID_SEM = {}
for sem, _ in pairs(IPT) do VALID_SEM[sem] = true end

-- 前向声明（指南 §7.1：local 不 hoisted；reset_rom_settings 在定义前调用它）
local release_all = nil

-- ---------- 运行时状态 ----------
local ioport = nil
local input_mgr = nil
local players = {}          -- 有序：{ {pl=0, name='P1', dirs={...}, buttons={...}} }
local dir_path = nil
local rom_name = nil
local frame_no = 0
local last_error = ''
local built = false
local overridden = {}       -- [field] = true  当前由本插件接管的字段
local menu_page = PAGE_MAIN -- 0=主页，1..n=players[i] 的分页
local last_actions = {}     -- actions[index] = 动作表

local settings = {
	master = true,          -- 全局总开关
	mode = 'burst',         -- 'burst' 连发 / 'hold' 持续按住
	on_frames = 2,          -- 连发：按下帧数
	off_frames = 2,         -- 连发：松开帧数
	on = {},                -- on[pl][sem] = true
}

-- ---------- 工具 ----------
local function safe(fn, default)
	local ok, v = pcall(fn)
	if ok then return v end
	return default
end

local function trim(s)
	return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function clamp(n, lo, hi)
	n = math.floor(n)
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

-- field.type（数字）→ 语义键
local function sem_of_type(ty)
	local n = tonumber(ty)
	if not n then return nil end
	for sem, val in pairs(IPT) do
		if val == n then return sem end
	end
	return nil
end

-- 玩家号：优先从字段标签解析（field.player 不可靠，见指南 §3.5）
--   "P1 Button 1" / "P1_JOYSTICK_UP" / "Player 2 Button 3" / "START2"
local function player_of(name, fplayer)
	local n = tostring(name or '')
	local p = n:match('[Pp]layer%s*(%d)')
		or n:match('[Pp](%d)[_ ]')
		or n:match('^[Ss][Tt][Aa][Rr][Tt](%d)')
	if p then return tonumber(p) - 1 end
	local fp = tonumber(fplayer)
	if fp ~= nil and fp >= 0 and fp <= 3 then return fp end
	return nil
end

-- ---------- 绑定文本 ----------
-- 手柄 token → "J1_B1" 形式
local function joy_short(token)
	local t = tostring(token):upper()
	local n, rest = t:match('^JOYCODE_(%d+)_(.+)$')
	if not n then return nil end
	local b = rest:match('^BUTTON(%d+)$')
	if b then return 'J' .. n .. '_B' .. b end
	local ax, ad = rest:match('^([XY])AXIS_(%a+)$')
	if ax and ad then
		local dir = ({ POS = '+', NEG = '-', INC = '+', DEC = '-' })[ad]
		if dir then return 'J' .. n .. '_' .. ax .. dir end
	end
	local sfx = rest:gsub('_SWITCH$', ''):gsub('AXIS_', '')
	if #sfx > 6 then sfx = sfx:sub(1, 6) end
	return 'J' .. n .. '_' .. sfx
end

-- 鼠标/光枪 token → "M1_B1" / "G1_B1"
local function mouse_short(token)
	local t = tostring(token):upper()
	local n, rest = t:match('^MOUSECODE_(%d+)_(.+)$')
	local prefix = 'M'
	if not n then
		n, rest = t:match('^GUNCODE_(%d+)_(.+)$')
		prefix = 'G'
	end
	if not n then return nil end
	local b = rest:match('^BUTTON(%d+)$')
	if b then return prefix .. n .. '_B' .. b end
	local ax, ad = rest:match('^([XY])AXIS_(%a+)$')
	if ax and ad then
		local dir = ({ POS = '+', NEG = '-', INC = '+', DEC = '-' })[ad]
		if dir then return prefix .. n .. '_' .. ax .. dir end
	end
	local sfx = rest:gsub('_SWITCH$', ''):gsub('AXIS_', '')
	if #sfx > 6 then sfx = sfx:sub(1, 6) end
	return prefix .. n .. '_' .. sfx
end

-- 把绑定序列拆成键盘/手柄/鼠标三路（每类取第一个）
local function seq_parts(seq)
	if not seq then return nil, nil, nil end
	local kb, joy, mouse = nil, nil, nil
	local toks = safe(function() return input_mgr:seq_to_tokens(seq) end, nil)
	if not toks then return nil, nil, nil end
	for tok in tostring(toks):upper():gmatch('[^%s]+') do
		if tok == 'OR' then
			-- 分隔符
		elseif not kb and tok:match('^KEYCODE_') then
			local code = safe(function() return input_mgr:code_from_token(tok) end, nil)
			if code ~= nil and code ~= 0 then
				local nm = safe(function() return input_mgr:code_name(code) end, nil)
				if nm and tostring(nm) ~= '' then kb = trim(nm) end
			end
			if not kb then kb = trim((tok:gsub('^KEYCODE_', ''))) end
		elseif not joy and tok:match('^JOYCODE_') then
			joy = joy_short(tok)
		elseif not mouse and (tok:match('^MOUSECODE_') or tok:match('^GUNCODE_')) then
			mouse = mouse_short(tok)
		end
	end
	return kb, joy, mouse
end

-- 三级回退取绑定序列（本游戏覆盖 → 字段默认 → 通用分配）
local function field_seq(f, ty, pl)
	local seq = safe(function() return f:input_seq('standard') end, nil)
	if seq and not safe(function() return seq.empty end, false) then return seq end
	local dseq = safe(function() return f:default_input_seq('standard') end, nil)
	if dseq and not safe(function() return dseq.empty end, false) then return dseq end
	if ty ~= nil then
		local tseq = safe(function() return ioport:type_seq(ty, pl or 0) end, nil)
		if tseq and not safe(function() return tseq.empty end, false) then return tseq end
	end
	return nil
end

-- 显示名：手柄 > 键盘 > 鼠标（用户既有的显示优先级偏好）
local function binding_text(f, ty, pl)
	local seq = field_seq(f, ty, pl)
	if not seq then return nil end
	local kb, joy, mouse = seq_parts(seq)
	return joy or kb or mouse
end

-- ---------- 收集输入字段 ----------
local function collect_players()
	local per = {}     -- per[pl][sem] = record
	local order = {}   -- 出现过真实控制字段的玩家

	for tag, port in pairs(ioport.ports) do
		local fields = safe(function() return port.fields end, nil)
		if fields then
			for key, f in pairs(fields) do
				local analog = safe(function() return f.is_analog end, false)
				local enabled = safe(function() return f.enabled end, true)
				local ty = safe(function() return f.type end, nil)
				local tc = safe(function() return f.type_class end, nil)
				local sem = sem_of_type(ty)
				-- 只要控制器类、非模拟、已启用的方向/按钮字段
				local is_ctrl = true
				if tc ~= nil then
					is_ctrl = (tostring(tc) == 'controller')
				elseif ty ~= nil then
					local n = tonumber(ty)
					is_ctrl = not (n == 5 or n == 6 or n == 7)   -- 排除 DIP/配置类
				end
				if sem and is_ctrl and (not analog) and enabled then
					local pl = player_of(key, safe(function() return f.player end, nil))
					if pl and pl >= 0 and pl <= 3 then
						per[pl] = per[pl] or {}
						if not per[pl][sem] then
							local bt = binding_text(f, ty, pl)
							if bt then    -- ★ 只收「已赋值」的
								per[pl][sem] = {
									sem = sem, pl = pl, field = f,
									name = tostring(key), type = ty,
									binding = bt,
								}
								order[pl] = true
							end
						end
					end
				end
			end
		end
	end

	-- 组装有序结构（方向固定顺序，按钮 1..16 升序）
	local out = {}
	for pl = 0, 3 do
		if order[pl] then
			local rec = { pl = pl, name = 'P' .. (pl + 1), dirs = {}, buttons = {} }
			for _, sem in ipairs(DIR_ORDER) do
				if per[pl] and per[pl][sem] then
					rec.dirs[#rec.dirs + 1] = per[pl][sem]
				end
			end
			for i = 1, MAX_BUTTONS do
				local sem = 'BUTTON' .. i
				if per[pl] and per[pl][sem] then
					rec.buttons[#rec.buttons + 1] = per[pl][sem]
				end
			end
			if #rec.dirs > 0 or #rec.buttons > 0 then
				out[#out + 1] = rec
			end
		end
	end
	return out
end

-- ---------- 持久化（§5.5：<homepath>/mame_autopress/）----------
local function cur_rom()
	if rom_name then return rom_name end
	local ok, n = pcall(function() return emu.romname() end)
	rom_name = ok and tostring(n) or 'unknown'
	return rom_name
end

local function rom_clean()
	return (cur_rom():gsub('[/\\:*?"<>|]', '_'))
end

local function global_path()
	return dir_path and (dir_path .. '/settings_global.json') or nil
end

local function rom_path()
	return dir_path and (dir_path .. '/settings_' .. rom_clean() .. '.json') or nil
end

local function read_json_file(p)
	if not p then return nil end
	local f = io.open(p, 'r')
	if not f then return nil end
	local text = f:read('a')
	f:close()
	if not text or text == '' then return nil end
	local ok, obj = pcall(function() return require('json').parse(text) end)
	if not ok or type(obj) ~= 'table' then return nil end
	return obj
end

local function write_json_file(p, obj)
	if not p then return false end
	local ok, txt = pcall(function() return require('json').stringify(obj) end)
	if not ok then
		last_error = 'stringify: ' .. tostring(txt)
		return false
	end
	local f = io.open(p, 'w')
	if not f then
		last_error = 'open(w): ' .. tostring(p)
		return false
	end
	f:write(txt)
	f:close()
	return true
end

-- 全局设置（跨 ROM）：总开关 / 模式 / 连发节奏
local function load_global()
	local obj = read_json_file(global_path())
	if type(obj) ~= 'table' then return end
	if type(obj.master) == 'boolean' then settings.master = obj.master end
	if obj.mode == 'burst' or obj.mode == 'hold' then settings.mode = obj.mode end
	if tonumber(obj.on_frames) then
		settings.on_frames = clamp(tonumber(obj.on_frames), FRAMES_MIN, FRAMES_MAX)
	end
	if tonumber(obj.off_frames) then
		settings.off_frames = clamp(tonumber(obj.off_frames), FRAMES_MIN, FRAMES_MAX)
	end
end

local function save_global()
	write_json_file(global_path(), {
		master = settings.master,
		mode = settings.mode,
		on_frames = settings.on_frames,
		off_frames = settings.off_frames,
	})
end

-- 本 ROM 设置：逐项开关 on[pl][sem]
local function apply_rom_obj(obj)
	if type(obj) ~= 'table' then return end
	if type(obj.on) ~= 'table' then return end
	local out = {}
	for k, v in pairs(obj.on) do
		-- 键形如 "p1"/"p2"，也容忍纯数字
		local pl = nil
		if type(k) == 'string' then
			local n = k:match('^[Pp](%d+)$') or k:match('^(%d+)$')
			pl = n and (tonumber(n) - 1) or nil
		elseif tonumber(k) then
			pl = tonumber(k) - 1
		end
		if pl and pl >= 0 and pl <= 3 and type(v) == 'table' then
			local m = {}
			for sem, on in pairs(v) do
				if on == true and VALID_SEM[tostring(sem)] then m[sem] = true end
			end
			if next(m) then out[pl] = m end
		end
	end
	settings.on = out
end

local function load_settings()
	settings.on = {}
	load_global()
	apply_rom_obj(read_json_file(rom_path()))
end

local function save_settings()
	local onOut = {}
	for pl, t in pairs(settings.on) do
		local m = {}
		for sem, v in pairs(t) do
			if v and VALID_SEM[sem] then m[sem] = true end
		end
		if next(m) then onOut['p' .. (pl + 1)] = m end
	end
	write_json_file(rom_path(), { on = onOut })
end

local function reset_rom_settings()
	local p = rom_path()
	if p then os.remove(p) end
	settings.on = {}
	release_all()
	save_settings()
end

-- ---------- 状态文件（诊断用）----------
local function write_status(phase)
	if not dir_path then return end
	local pays = {}
	for _, p in ipairs(players) do
		local on_cnt = 0
		local pm = settings.on[p.pl]
		if pm then for _, v in pairs(pm) do if v then on_cnt = on_cnt + 1 end end end
		pays[#pays + 1] = {
			pl = p.pl, dirs = #p.dirs, buttons = #p.buttons, on = on_cnt,
		}
	end
	local payload = {
		plugin = 'mame_autopress', version = exports.version,
		phase = phase or 'frame', rom = safe(function() return cur_rom() end, '?'),
		frame = frame_no, built = built, players = #players, detail = pays,
		master = settings.master, mode = settings.mode,
		on_frames = settings.on_frames, off_frames = settings.off_frames,
		last_error = last_error, ts = os.time(),
	}
	write_json_file(dir_path .. '/status.json', payload)
end

-- ---------- 按键写入 ----------
local function write_field(field, state)
	if state == 1 then
		safe(function() field:set_value(1) end)
	else
		-- 松开相必须显式写 0（§3.8 / copilot2p 4.9.3：clear_value 会被物理输入顶回）
		safe(function() field:set_value(0) end)
	end
	overridden[field] = true
end

local function release_field(field)
	if overridden[field] then
		safe(function() field:clear_value() end)
		overridden[field] = nil
	end
end

-- 赋值而非 local function —— 保持顶部前向声明有效（指南 §7.1）
release_all = function()
	local keys = {}
	for k in pairs(overridden) do keys[#keys + 1] = k end
	for _, k in ipairs(keys) do release_field(k) end
	overridden = {}
end

local function entry_on(pl, sem)
	local m = settings.on[pl]
	return (m ~= nil) and (m[sem] == true)
end

-- ---------- 主循环 ----------
local function build()
	ioport = manager.machine.ioport
	input_mgr = manager.machine.input
	players = collect_players()
	overridden = {}
	emu.print_info(string.format('[mame_autopress] built players=%d', #players))
	for _, p in ipairs(players) do
		emu.print_verbose(string.format('[mame_autopress] %s dirs=%d buttons=%d',
			p.name, #p.dirs, #p.buttons))
	end
end

local function tick()
	frame_no = frame_no + 1

	if not built then
		built = true
		local ok, err = pcall(build)
		if not ok then last_error = 'build: ' .. tostring(err) end
		write_status('built')
	end

	if frame_no % 60 == 0 then write_status() end

	if not settings.master then
		release_all()
		return
	end

	local period = settings.on_frames + settings.off_frames
	local burst_on = (frame_no % period) < settings.on_frames

	for _, p in ipairs(players) do
		local pm = settings.on[p.pl]
		for _, it in ipairs(p.dirs) do
			if pm and pm[it.sem] then
				write_field(it.field, (settings.mode == 'hold') and 1 or (burst_on and 1 or 0))
			else
				release_field(it.field)
			end
		end
		for _, it in ipairs(p.buttons) do
			if pm and pm[it.sem] then
				write_field(it.field, (settings.mode == 'hold') and 1 or (burst_on and 1 or 0))
			else
				release_field(it.field)
			end
		end
	end
end

-- ---------- 菜单 ----------
local function menu_items()
	local items = {}
	local actions = {}

	local function push(label, value, flags, act)
		items[#items + 1] = { label, value or '', flags or 'off' }
		actions[#items] = act or nil   -- ★ 必须是 #items（指南 §2.2）
	end
	local function head(label, value) push(label, value, 'heading') end
	local function sep() push('---', '', 'off') end
	local function disp(label, value) push(label, value, 'off') end
	local function act(label, value, a) push(label, value, '', a) end
	local function toggle(label, on, a) push(label, (on and 'ON' or 'OFF'), 'lr', a) end
	local function adj(label, value, a) push(label, value, 'lr', a) end

	-- 子页：某个玩家的方向/按键
	if menu_page ~= PAGE_MAIN then
		local p = players[menu_page]
		if not p then
			menu_page = PAGE_MAIN
		else
			head(string.format('%s 玩家', p.name),
				string.format('%d 方向 · %d 按键', #p.dirs, #p.buttons))
			if #p.dirs > 0 then
				head('方向', '左右键切换 ON/OFF')
				for _, it in ipairs(p.dirs) do
					toggle(string.format('%s  (%s)', DIR_LABEL[it.sem] or it.sem, it.binding),
						entry_on(p.pl, it.sem),
						{ kind = 'toggle', pl = p.pl, sem = it.sem })
				end
			end
			if #p.buttons > 0 then
				head('按键', '左右键切换 ON/OFF')
				for idx, it in ipairs(p.buttons) do
					toggle(string.format('按钮 %d  (%s)', idx, it.binding),
						entry_on(p.pl, it.sem),
						{ kind = 'toggle', pl = p.pl, sem = it.sem })
				end
			end
			sep()
			act('全部开启（本玩家）', '', { kind = 'all_on', pl = p.pl })
			act('全部关闭（本玩家）', '', { kind = 'all_off', pl = p.pl })
			act('← 返回上级', '', { kind = 'back' })
			last_actions = actions
			return items
		end
	end

	-- 主页
	head('自动按键', string.format('v%s · %d 位玩家', exports.version, #players))
	if #players == 0 then
		disp('正在读取输入…', '关闭菜单后重开')
	end
	for i, p in ipairs(players) do
		act(string.format('%s 玩家（分页）', p.name),
			string.format('%d 方向 · %d 按键', #p.dirs, #p.buttons),
			{ kind = 'page', page = i })
	end
	sep()
	head('全局', '所有玩家共用')
	toggle('总开关', settings.master, { kind = 'master' })
	adj('模式（左右切换）', (settings.mode == 'burst') and '连发' or '持续按住', { kind = 'mode' })
	adj('连发·按下帧', tostring(settings.on_frames), { kind = 'on_frames' })
	adj('连发·松开帧', tostring(settings.off_frames), { kind = 'off_frames' })
	act('全部开启（所有玩家）', '', { kind = 'all_on' })
	act('全部关闭（所有玩家）', '', { kind = 'all_off' })
	act('重置本 ROM 配置', 'settings_' .. rom_clean() .. '.json', { kind = 'reset_rom' })
	sep()
	disp('状态', string.format('rom=%s  frame=%d%s',
		safe(function() return cur_rom() end, '?'), frame_no,
		(last_error ~= '') and ('  err=' .. last_error) or ''))

	last_actions = actions
	return items
end

local function set_all(pl, on)
	for _, p in ipairs(players) do
		if pl == nil or p.pl == pl then
			local m = settings.on[p.pl] or {}
			for _, it in ipairs(p.dirs) do m[it.sem] = on end
			for _, it in ipairs(p.buttons) do m[it.sem] = on end
			if next(m) then settings.on[p.pl] = m end
		end
	end
	save_settings()
end

local function menu_callback(index, event)
	-- 先处理返回（此时 index 无意义）
	if event == 'back' then
		if menu_page ~= PAGE_MAIN then
			menu_page = PAGE_MAIN
			return true
		end
		return false
	end

	local a = last_actions[index]
	if not a then return false end
	local k = a.kind
	local is_select = (event == 'select')
	local is_lr = (event == 'left' or event == 'right')

	if k == 'page' then
		if is_select then
			menu_page = a.page
			return true
		end
		return false

	elseif k == 'back' then
		if is_select then
			menu_page = PAGE_MAIN
			return true
		end
		return false

	elseif k == 'toggle' then
		if is_select or is_lr then
			settings.on[a.pl] = settings.on[a.pl] or {}
			settings.on[a.pl][a.sem] = not entry_on(a.pl, a.sem)
			save_settings()
			return true
		end
		return false

	elseif k == 'master' then
		if is_select or is_lr then
			settings.master = not settings.master
			if not settings.master then release_all() end
			save_global()
			return true
		end
		return false

	elseif k == 'mode' then
		if is_select or is_lr then
			settings.mode = (settings.mode == 'burst') and 'hold' or 'burst'
			save_global()
			return true
		end
		return false

	elseif k == 'on_frames' then
		if is_lr then
			local d = (event == 'right') and 1 or -1
			settings.on_frames = clamp(settings.on_frames + d, FRAMES_MIN, FRAMES_MAX)
			save_global()
			return true
		end
		return false

	elseif k == 'off_frames' then
		if is_lr then
			local d = (event == 'right') and 1 or -1
			settings.off_frames = clamp(settings.off_frames + d, FRAMES_MIN, FRAMES_MAX)
			save_global()
			return true
		end
		return false

	elseif k == 'all_on' then
		if is_select then
			settings.master = true
			set_all(a.pl, true)
			save_global()
			return true
		end
		return false

	elseif k == 'all_off' then
		if is_select then
			set_all(a.pl, false)
			release_all()
			return true
		end
		return false

	elseif k == 'reset_rom' then
		if is_select then
			reset_rom_settings()
			return true
		end
		return false
	end

	return false
end

-- ---------- 启动 ----------
local function ensure_dir(d)
	if not d then return false end
	local ok, lfs = pcall(require, 'lfs')
	if not ok or not lfs then return false end
	if safe(function() return lfs.attributes(d) end, nil) then return true end
	pcall(function() lfs.mkdir(d) end)
	return safe(function() return lfs.attributes(d) end, nil) ~= nil
end

function mame_autopress.startplugin()
	local home = safe(function()
		return manager.options.entries.homepath:value():match('([^;]+)')
	end, '.')
	dir_path = (home or '.') .. '/mame_autopress'
	ensure_dir(dir_path)

	-- 写入探针：目录不可写时所有保存都会静默失败，必须尽早暴露
	local probe = dir_path .. '/.write_probe'
	local pf = io.open(probe, 'w')
	if pf then
		pf:write('ok')
		pf:close()
		os.remove(probe)
	else
		last_error = 'dir not writable: ' .. tostring(dir_path)
		emu.print_error('[mame_autopress] ' .. last_error)
	end

	prestart_subscription = emu.register_prestart(function()
		built = false
		players = {}
		rom_name = nil
		last_error = ''
		menu_page = PAGE_MAIN
		release_all()
		load_settings()
		write_status('prestart')
	end)

	frame_subscription = emu.add_machine_frame_notifier(function()
		local ok, err = pcall(tick)
		if not ok then last_error = 'tick: ' .. tostring(err) end
	end)

	stop_subscription = emu.add_machine_stop_notifier(function()
		release_all()
		save_settings()
		write_status('stopped')
	end)

	emu.register_menu(menu_callback, menu_items, _p('plugin-mame_autopress', '自动按键'))
	emu.print_info(string.format('[mame_autopress] v%s 已启动（配置目录 %s）',
		exports.version, tostring(dir_path)))
end

return exports
