-- test_mock_cases.lua —— 在 mock 环境里真跑插件，断言行为而非"能加载"
-- 返回 { {name=..., ok=..., msg=...}, ... }

local MOCK = _G.MOCK
local json = require('json')

local R = {}

local function check(name, cond, msg)
	R[#R + 1] = { name = name, ok = (cond and true or false), msg = msg or '' }
end

local function read_json(p)
	local f = io.open(p, 'r')
	if not f then return nil end
	local t = f:read('a')
	f:close()
	if not t or t == '' then return nil end
	local ok, v = pcall(json.parse, t)
	if not ok then return nil end
	return v
end

local function find_row(items, pat)
	for i, it in ipairs(items) do
		if tostring(it[1]):find(pat) then return i, it end
	end
	return nil, nil
end

local function labels(items)
	local out = {}
	for _, it in ipairs(items) do out[#out + 1] = tostring(it[1]) end
	return table.concat(out, ' | ')
end

local function boot(source)
	MOCK.setup_game()
	local exports = LOAD_PLUGIN(source)
	exports.startplugin()
	if MOCK.prestart_cb then MOCK.prestart_cb() end
	if MOCK.frame_cb then MOCK.frame_cb() end
	return exports
end

local function values_of(calls, field_name)
	local out = {}
	for _, c in ipairs(calls) do
		if c.name == field_name then out[#out + 1] = c.v end
	end
	return out
end

local function count_of(calls, field_name)
	local n = 0
	for _, c in ipairs(calls) do
		if c.name == field_name then n = n + 1 end
	end
	return n
end

function RUN_ALL(source, expect_version)
	R = {}
	expect_version = expect_version or '1.0.2'

	-- ===== T2 元信息 =====
	local exports = boot(source)
	check('exports.name = mame_autopress', exports.name == 'mame_autopress', tostring(exports.name))
	check('exports.version = ' .. expect_version, exports.version == expect_version, tostring(exports.version))
	check('exports.description 非空', type(exports.description) == 'string' and #exports.description > 10)

	-- ===== T3 启动注册 =====
	check('register_menu 只调一次', MOCK.calls.menu_registered == 1, tostring(MOCK.calls.menu_registered))
	check('菜单标题中文', MOCK.menu_title == '自动按键', tostring(MOCK.menu_title))
	check('有 prestart 订阅', type(MOCK.prestart_cb) == 'function')
	check('有 frame 订阅', type(MOCK.frame_cb) == 'function')
	check('有 stop 订阅', type(MOCK.stop_cb) == 'function')
	check('启动日志已打印', #MOCK.calls.info >= 1, table.concat(MOCK.calls.info, ' | '))

	-- ===== T4 首帧收集 =====
	local status = read_json(MOCK.homepath .. '/mame_autopress/status.json')
	check('status.json 已写入', status ~= nil)
	if status then
		check('识别 2 位玩家', status.players == 2, tostring(status.players))
		check('P1 有 4 方向', status.detail[1] and status.detail[1].dirs == 4,
			status.detail[1] and tostring(status.detail[1].dirs) or 'nil')
		check('P1 有 3 按键（无绑定的 Button4 被排除）',
			status.detail[1] and status.detail[1].buttons == 3,
			status.detail[1] and tostring(status.detail[1].buttons) or 'nil')
		check('P2 有 2 按键（Button3 无绑定被排除）',
			status.detail[2] and status.detail[2].buttons == 2,
			status.detail[2] and tostring(status.detail[2].buttons) or 'nil')
		check('无 last_error', (status.last_error or '') == '', tostring(status.last_error))
	end

	-- ===== T5 主页菜单 =====
	local items = MOCK.menu_items()
	local main_txt = labels(items)
	check('主页有 P1 分页入口', find_row(items, 'P1 玩家') ~= nil, main_txt)
	check('主页有 P2 分页入口', find_row(items, 'P2 玩家') ~= nil, main_txt)
	check('主页有总开关', find_row(items, '^总开关') ~= nil, main_txt)
	check('主页有模式切换', find_row(items, '^模式') ~= nil, main_txt)
	check('主页有全开/全关', find_row(items, '全部开启') ~= nil and find_row(items, '全部关闭') ~= nil, main_txt)

	-- ===== T5b 按键级总开关（跨玩家、按按键语义聚合，只在有赋值的按键上生成）=====
	local idx_master = find_row(items, '^总开关%s*$')
	local idx_k1 = find_row(items, '^总开关（按键 1）')
	local idx_k2 = find_row(items, '^总开关（按键 2）')
	local idx_k3 = find_row(items, '^总开关（按键 3）')
	check('主页有「总开关」行', idx_master ~= nil, main_txt)
	check('有「总开关（按键 1）」', idx_k1 ~= nil, main_txt)
	check('有「总开关（按键 2）」', idx_k2 ~= nil, main_txt)
	check('有「总开关（按键 3）」（只有 P1 有该键也生成）', idx_k3 ~= nil, main_txt)
	check('没有「总开关（按键 4）」（无赋值不生成）', find_row(items, '^总开关（按键 4）') == nil, main_txt)
	check('三个分组行紧跟总开关之后',
		(idx_master ~= nil) and (idx_k1 == idx_master + 1) and (idx_k2 == idx_master + 2)
		and (idx_k3 == idx_master + 3), main_txt)
	check('初始三个分组都是 OFF',
		(idx_k1 and items[idx_k1][2] == 'OFF') and (idx_k2 and items[idx_k2][2] == 'OFF')
		and (idx_k3 and items[idx_k3][2] == 'OFF'),
		tostring(idx_k1 and items[idx_k1][2]) .. '/' .. tostring(idx_k2 and items[idx_k2][2]))

	-- ===== T6 P1 分页内容 =====
	local idx_p1 = find_row(items, 'P1 玩家')
	local ret = MOCK.menu_cb(idx_p1, 'select')
	check('进入 P1 分页返回 true', ret == true, tostring(ret))
	items = MOCK.menu_items()
	local page_txt = labels(items)
	check('分页含 上/下/左/右', find_row(items, '^上') ~= nil and find_row(items, '^下') ~= nil
		and find_row(items, '^左') ~= nil and find_row(items, '^右') ~= nil, page_txt)
	check('分页含 3 个按钮行', find_row(items, '^按钮 1') ~= nil and find_row(items, '^按钮 2') ~= nil
		and find_row(items, '^按钮 3') ~= nil, page_txt)
	check('分页不含按钮 4（无绑定）', find_row(items, '^按钮 4') == nil, page_txt)
	-- 行标签只留名称，不再拼绑定括号（用户 2026-11-10 明确要求去掉「上 (J1_YUP)」这种尾巴）
	local up_it = select(2, find_row(items, '^上'))
	local b1_it = select(2, find_row(items, '^按钮 1'))
	check('方向行标签恰为「上」，不带绑定括号', (up_it ~= nil) and (up_it[1] == '上'),
		tostring(up_it and up_it[1]))
	check('按钮行标签恰为「按钮 1」，不带绑定括号', (b1_it ~= nil) and (b1_it[1] == '按钮 1'),
		tostring(b1_it and b1_it[1]))
	check('分页内不出现任何绑定名（J1_ / KEYCODE / JOYCODE）',
		page_txt:find('J1_', 1, true) == nil and page_txt:find('KEYCODE', 1, true) == nil
		and page_txt:find('JOYCODE', 1, true) == nil, page_txt)
	check('分页有返回上级行', find_row(items, '返回上级') ~= nil, page_txt)

	-- ===== T6b「全部按键开启（本玩家）」=====
	local idx_all_on = find_row(items, '^全部开启（本玩家）')
	local idx_btn_on = find_row(items, '^全部按键开启（本玩家）')
	local idx_all_off = find_row(items, '^全部关闭（本玩家）')
	check('分页有「全部按键开启（本玩家）」', idx_btn_on ~= nil, page_txt)
	check('「全部按键开启」夹在全部开启与全部关闭之间',
		(idx_all_on ~= nil) and (idx_btn_on == idx_all_on + 1) and (idx_all_off == idx_btn_on + 1),
		page_txt)
	check('点「全部按键开启」返回 true', MOCK.menu_cb(idx_btn_on, 'select') == true)
	local brset = read_json(MOCK.homepath .. '/mame_autopress/settings_xmen.json')
	check('全部按键开启 → BUTTON1/2/3 都为 true',
		brset and brset.on and brset.on.p1 and brset.on.p1.BUTTON1 == true
		and brset.on.p1.BUTTON2 == true and brset.on.p1.BUTTON3 == true,
		brset and json.stringify(brset.on or {}) or 'nil')
	check('全部按键开启 → 方向未被动到（UP 仍非 true）',
		not (brset and brset.on and brset.on.p1 and brset.on.p1.UP == true),
		brset and json.stringify(brset.on or {}) or 'nil')
	local gb = read_json(MOCK.homepath .. '/mame_autopress/settings_global.json')
	check('全部按键开启 → 总开关被置为 ON（否则写了不生效）', gb and gb.master == true,
		gb and json.stringify(gb) or 'nil')
	items = MOCK.menu_items()
	MOCK.menu_cb(find_row(items, '^全部关闭（本玩家）'), 'select')
	local brset2 = read_json(MOCK.homepath .. '/mame_autopress/settings_xmen.json')
	check('收尾：全部关闭后 P1 无开启项（为后续用例复位）',
		not (brset2 and brset2.on and brset2.on.p1 and (brset2.on.p1.UP == true
			or brset2.on.p1.BUTTON1 == true or brset2.on.p1.BUTTON2 == true
			or brset2.on.p1.BUTTON3 == true)),
		brset2 and json.stringify(brset2.on or {}) or 'nil')

	-- ===== T7 切换开关 + 动作对齐 =====
	local idx_up = find_row(items, '^上')
	MOCK.menu_cb(idx_up, 'select')
	local romset = read_json(MOCK.homepath .. '/mame_autopress/settings_xmen.json')
	check('切换后 settings_xmen.json 已落盘', romset ~= nil)
	check('p1.UP = true', romset and romset.on and romset.on.p1 and romset.on.p1.UP == true,
		romset and json.stringify(romset.on or {}) or 'nil')

	-- 点"按钮 2"必须只改 BUTTON2（actions[#list] 错位会改到别的行）
	items = MOCK.menu_items()
	local idx_b2 = find_row(items, '^按钮 2')
	MOCK.menu_cb(idx_b2, 'select')
	romset = read_json(MOCK.homepath .. '/mame_autopress/settings_xmen.json')
	check('按钮 2 → BUTTON2 = true', romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON2 == true,
		romset and json.stringify(romset.on or {}) or 'nil')
	check('按钮 2 → BUTTON1 仍为 nil（未错位）',
		not (romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON1 ~= nil),
		romset and json.stringify(romset.on or {}) or 'nil')

	-- ===== T7b 按键级总开关：混合态 / 右键全开 / 左键全关 =====
	-- T7 结束时停在 P1 分页；先用「按钮 1」制造混合态（P1 开、P2 关），再回主页
	local p1page_items = MOCK.menu_items()
	local idx_b1 = find_row(p1page_items, '^按钮 1')
	MOCK.menu_cb(idx_b1, 'select')
	MOCK.menu_cb(1, 'back')
	local sp = MOCK.homepath .. '/mame_autopress/settings_xmen.json'
	items = MOCK.menu_items()
	local m1 = find_row(items, '^总开关（按键 1）')
	check('P1 开了按钮 1 而 P2 没开 → 分组显示「混合」',
		(items[m1] ~= nil) and (items[m1][2] == '混合'),
		tostring(items[m1] and items[m1][2]))
	check('按键 1 分组右键返回 true', MOCK.menu_cb(m1, 'right') == true)
	romset = read_json(sp)
	check('右键 → P1.BUTTON1 = true',
		romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON1 == true,
		romset and json.stringify(romset.on or {}) or 'nil')
	check('右键 → P2.BUTTON1 = true（跨玩家）',
		romset and romset.on and romset.on.p2 and romset.on.p2.BUTTON1 == true,
		romset and json.stringify(romset.on or {}) or 'nil')
	items = MOCK.menu_items()
	m1 = find_row(items, '^总开关（按键 1）')
	check('全开后按键 1 分组显示 ON', (items[m1] ~= nil) and (items[m1][2] == 'ON'),
		tostring(items[m1] and items[m1][2]))
	check('按键 1 分组左键返回 true', MOCK.menu_cb(m1, 'left') == true)
	romset = read_json(sp)
	check('左键 → P1.BUTTON1 不再为 true',
		romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON1 ~= true,
		romset and json.stringify(romset.on or {}) or 'nil')
	check('左键 → P2.BUTTON1 不再为 true',
		not (romset and romset.on and romset.on.p2 and romset.on.p2.BUTTON1 == true),
		romset and json.stringify(romset.on or {}) or 'nil')
	items = MOCK.menu_items()
	m1 = find_row(items, '^总开关（按键 1）')
	check('全关后按键 1 分组显示 OFF', (items[m1] ~= nil) and (items[m1][2] == 'OFF'),
		tostring(items[m1] and items[m1][2]))

	-- 只有 P1 有的按键 3：右键只影响 P1，且不串到按键 1（此刻按键 1 已全关）
	local m3 = find_row(items, '^总开关（按键 3）')
	check('按键 3 分组右键可操作', MOCK.menu_cb(m3, 'right') == true)
	romset = read_json(sp)
	check('按键 3 只影响 P1：P1.BUTTON3 = true',
		romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON3 == true,
		romset and json.stringify(romset.on or {}) or 'nil')
	check('按键 3 不串到按键 1（P1.BUTTON1 仍非 true）',
		romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON1 ~= true,
		romset and json.stringify(romset.on or {}) or 'nil')
	check('按键级开关不动 T7 开的 P1.BUTTON2',
		romset and romset.on and romset.on.p1 and romset.on.p1.BUTTON2 == true,
		romset and json.stringify(romset.on or {}) or 'nil')

	-- 恢复现场：后续 T9 断言期望此时停在 P1 分页（子页 back 应返回 true）
	local home_items = MOCK.menu_items()
	local idx_p1b = find_row(home_items, 'P1 玩家')
	MOCK.menu_cb(idx_p1b, 'select')

	-- ===== T8 连发写入（默认 on=1/off=1，4 帧应是 1,0,1,0）=====
	MOCK.calls.set_value = {}
	for _ = 1, 4 do MOCK.frame_cb() end
	local up_vals = values_of(MOCK.calls.set_value, 'P1_JOYSTICK_UP')
	check('tick 对已开启字段调用 set_value', #up_vals == 4, 'count=' .. tostring(#up_vals))
	local ones, zeros = 0, 0
	for _, v in ipairs(up_vals) do
		if v == 1 then ones = ones + 1 elseif v == 0 then zeros = zeros + 1 end
	end
	check('连发 4 帧内出现按下(1)', ones >= 1, json.stringify(up_vals))
	check('连发 4 帧内出现松开(0)', zeros >= 1, json.stringify(up_vals))
	-- 默认 on=1/off=1 时 4 帧应是逐帧交替（1,0,1,0 或 0,1,0,1）：相邻变化 3 次。
	-- 若默认退回 2/2（1,1,0,0），变化只有 1 次，此断言会失败。
	local alternates = 0
	for i = 2, #up_vals do
		if up_vals[i] ~= up_vals[i - 1] then alternates = alternates + 1 end
	end
	check('默认节奏 1/1：4 帧逐帧交替（变化 3 次）', alternates == 3, json.stringify(up_vals))
	local b2_vals = values_of(MOCK.calls.set_value, 'P1 Button 2')
	check('已开启的按钮也被写入', #b2_vals == 4, 'count=' .. tostring(#b2_vals))

	-- 未开启字段不应被写入
	local left_vals = values_of(MOCK.calls.set_value, 'P1_JOYSTICK_LEFT')
	check('未开启的字段不写入', #left_vals == 0, 'count=' .. tostring(#left_vals))

	-- ===== T10 子页 back =====
	check('子页 back 返回 true', MOCK.menu_cb(1, 'back') == true)
	items = MOCK.menu_items()
	check('back 后回到主页', find_row(items, '^总开关') ~= nil, labels(items))
	check('主页 back 返回 false（放行给 MAME）', MOCK.menu_cb(1, 'back') == false)

	-- ===== T9 总开关 =====
	items = MOCK.menu_items()
	local idx_master = find_row(items, '^总开关')
	MOCK.calls.set_value = {}
	MOCK.calls.clear_value = {}
	MOCK.menu_cb(idx_master, 'select')
	local g = read_json(MOCK.homepath .. '/mame_autopress/settings_global.json')
	check('总开关落盘 master=false', g and g.master == false, g and json.stringify(g) or 'nil')
	for _ = 1, 2 do MOCK.frame_cb() end
	check('总开关关闭后不再写入', count_of(MOCK.calls.set_value, 'P1_JOYSTICK_UP') == 0,
		'count=' .. tostring(count_of(MOCK.calls.set_value, 'P1_JOYSTICK_UP')))
	check('总开关关闭后归还字段', count_of(MOCK.calls.clear_value, 'P1_JOYSTICK_UP') >= 1,
		'count=' .. tostring(count_of(MOCK.calls.clear_value, 'P1_JOYSTICK_UP')))

	-- ===== T11 重启后配置保持 =====
	exports = boot(source)
	items = MOCK.menu_items()
	local idx_p1b = find_row(items, 'P1 玩家')
	MOCK.menu_cb(idx_p1b, 'select')
	items = MOCK.menu_items()
	local idx_up2, row_up2 = find_row(items, '^上')
	check('重启后 p1.UP 仍为 ON', row_up2 ~= nil and row_up2[2] == 'ON',
		row_up2 and tostring(row_up2[2]) or 'nil')
	local idx_b2b, row_b2b = find_row(items, '^按钮 2')
	check('重启后 p1.BUTTON2 仍为 ON', row_b2b ~= nil and row_b2b[2] == 'ON',
		row_b2b and tostring(row_b2b[2]) or 'nil')
	-- 总开关是全球设置，重启后应为 false
	MOCK.menu_cb(1, 'back')
	items = MOCK.menu_items()
	local _, row_master = find_row(items, '^总开关')
	check('重启后总开关仍为 OFF', row_master ~= nil and row_master[2] == 'OFF',
		row_master and tostring(row_master[2]) or 'nil')

	-- ===== T12 hold 模式 =====
	items = MOCK.menu_items()
	local idx_mode = find_row(items, '^模式')
	MOCK.menu_cb(idx_mode, 'select')   -- burst → hold
	local _, row_mode = find_row(MOCK.menu_items(), '^模式')
	check('模式切到 持续按住', row_mode ~= nil and row_mode[2] == '持续按住',
		row_mode and tostring(row_mode[2]) or 'nil')
	-- 重新打开总开关
	items = MOCK.menu_items()
	MOCK.menu_cb(find_row(items, '^总开关'), 'select')
	MOCK.calls.set_value = {}
	for _ = 1, 4 do MOCK.frame_cb() end
	local up_hold = values_of(MOCK.calls.set_value, 'P1_JOYSTICK_UP')
	check('hold 模式 4 帧全部为 1', #up_hold == 4 and up_hold[1] == 1 and up_hold[4] == 1,
		json.stringify(up_hold))

	-- ===== T13 全关 =====
	items = MOCK.menu_items()
	MOCK.menu_cb(find_row(items, '^全部关闭'), 'select')
	romset = read_json(MOCK.homepath .. '/mame_autopress/settings_xmen.json')
	local p1on = romset and romset.on and romset.on.p1 or {}
	local n_on = 0
	for _, v in pairs(p1on) do if v then n_on = n_on + 1 end end
	check('全部关闭后 p1 无开启项', n_on == 0, json.stringify(p1on))

	-- ===== T14 保存为默认 / 重置本 ROM（插件级两项）=====
	local CFG = MOCK.homepath .. '/mame_autopress/'
	local function go_p1()
		MOCK.menu_cb(find_row(MOCK.menu_items(), 'P1 玩家'), 'select')
		return MOCK.menu_items()
	end
	local function home()
		MOCK.menu_cb(1, 'back')
		return MOCK.menu_items()
	end
	local function row_state(pat)
		local _, row = find_row(go_p1(), pat)
		local st = row and row[2] or 'nil'
		home()
		return st
	end

	-- 主页必须有这两项（以后再开发任何 MAME 插件都要有）
	items = MOCK.menu_items()
	check('主页有「保存为默认（其他 ROM 通用）」', find_row(items, '保存为默认') ~= nil, labels(items))
	check('主页有「重置本 ROM（回落到默认）」', find_row(items, '重置本 ROM') ~= nil, labels(items))
	check('保存为默认 右侧显示目标文件',
		(find_row(items, '保存为默认') and select(2, find_row(items, '保存为默认'))[2]:find('settings_default.json') ~= nil),
		labels(items))

	-- 先只开「上」，存为默认
	MOCK.menu_cb(find_row(go_p1(), '^上'), 'select')
	home()
	MOCK.menu_cb(find_row(MOCK.menu_items(), '保存为默认'), 'select')
	local def = read_json(CFG .. 'settings_default.json')
	check('保存为默认 → settings_default.json 落盘', def ~= nil)
	check('默认里含 p1.UP = true', def and def.on and def.on.p1 and def.on.p1.UP == true,
		def and json.stringify(def.on or {}) or 'nil')
	check('默认记录了来源 ROM', def ~= nil and def.from_rom == 'xmen', def and tostring(def.from_rom) or 'nil')

	-- 再开「按钮 2」，此时本 ROM 比默认多一项
	MOCK.menu_cb(find_row(go_p1(), '^按钮 2'), 'select')
	home()
	check('本 ROM 此时 按钮 2 = ON', row_state('^按钮 2') == 'ON')

	-- 换一个没有自己配置的 ROM（neogeo）→ 应继承默认：UP 开、按钮 2 关
	MOCK.rom = 'neogeo'
	exports = boot(source)
	check('新 ROM 继承默认：上 = ON', row_state('^上') == 'ON')
	check('新 ROM 继承默认：按钮 2 = OFF（默认里没有）', row_state('^按钮 2') == 'OFF')
	check('新 ROM 未生成自己的配置文件（只是继承默认）', read_json(CFG .. 'settings_neogeo.json') == nil)

	-- 切回 xmen → 读自己的配置（比默认多一个按钮 2）
	MOCK.rom = 'xmen'
	exports = boot(source)
	check('切回本 ROM：按钮 2 仍为 ON（本 ROM 覆盖默认）', row_state('^按钮 2') == 'ON')

	-- 重置本 ROM → 删除自己的文件、回落默认（按钮 2 应变 OFF）
	items = MOCK.menu_items()
	MOCK.menu_cb(find_row(items, '重置本 ROM'), 'select')
	check('重置后 settings_xmen.json 已删除', read_json(CFG .. 'settings_xmen.json') == nil)
	local bakf = io.open(CFG .. 'settings_xmen.json.bak', 'r')
	check('重置后留了 .bak 备份', bakf ~= nil)
	if bakf then bakf:close() end
	check('重置后回落到默认：上 = ON', row_state('^上') == 'ON')
	check('重置后回落到默认：按钮 2 = OFF', row_state('^按钮 2') == 'OFF')

	return R
end
