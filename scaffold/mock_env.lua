-- mock_env.lua —— MAME 插件运行环境的 Lua 模拟层（仅用于 lupa 回归测试）
-- 依据《MAME插件开发避坑指南》§6.1：
--   seq 自带 tokens、每个 (玩家,输入) 的 ioport type 全局唯一、键盘 code 一一对应。
-- 关键语义必须与 MAME 一致，否则测试会"假通过"（§6.2）：
--   set_value(v) 记录逻辑值；clear_value() 记录归还；input_seq 未绑定时返回 empty=true。

local M = {}

M.homepath = '.'
M.rom = 'xmen'

M.calls = {
	info = {}, verbose = {}, error = {},
	set_value = {}, clear_value = {},
	menu_registered = 0,
}

function M.reset_calls()
	M.calls.info = {}
	M.calls.verbose = {}
	M.calls.error = {}
	M.calls.set_value = {}
	M.calls.clear_value = {}
	M.calls.menu_registered = 0
	M.prestart_cb = nil
	M.frame_cb = nil
	M.stop_cb = nil
	M.menu_cb = nil
	M.menu_items = nil
	M.menu_title = nil
end

-- ---------- mini json（stringify / parse，够本插件用）----------
local json = {}

local function json_esc(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		local map = {
			['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
			['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
		}
		if map[c] then return map[c] end
		return string.format('\\u%04x', c:byte())
	end) .. '"'
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' then return false end
		n = n + 1
	end
	return n == #t
end

function json.stringify(v)
	local t = type(v)
	if v == nil then return 'null' end
	if t == 'boolean' then return tostring(v) end
	if t == 'number' then
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format('%d', v)
		end
		return tostring(v)
	end
	if t == 'string' then return json_esc(v) end
	if t ~= 'table' then return 'null' end
	if is_array(v) then
		local parts = {}
		for i = 1, #v do parts[#parts + 1] = json.stringify(v[i]) end
		return '[' .. table.concat(parts, ',') .. ']'
	end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = json_esc(k) .. ':' .. json.stringify(v[k])
	end
	return '{' .. table.concat(parts, ',') .. '}'
end

function json.parse(s)
	local i = 1
	local function err(msg) error('json: ' .. msg .. ' at ' .. i) end
	local function skip()
		while i <= #s do
			local c = s:sub(i, i)
			if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
				i = i + 1
			else
				break
			end
		end
	end
	local parse_value
	local function parse_string()
		i = i + 1
		local buf = {}
		while i <= #s do
			local c = s:sub(i, i)
			if c == '"' then
				i = i + 1
				return table.concat(buf)
			end
			if c == '\\' then
				local n = s:sub(i + 1, i + 1)
				local map = {
					['"'] = '"', ['\\'] = '\\', ['/'] = '/',
					['n'] = '\n', ['r'] = '\r', ['t'] = '\t',
					['b'] = '\b', ['f'] = '\f',
				}
				if n == 'u' then
					local hex = s:sub(i + 2, i + 5)
					buf[#buf + 1] = utf8.char(tonumber(hex, 16) or 63)
					i = i + 6
				else
					buf[#buf + 1] = map[n] or n
					i = i + 2
				end
			else
				buf[#buf + 1] = c
				i = i + 1
			end
		end
		err('unterminated string')
	end
	local function parse_number()
		local start = i
		if s:sub(i, i) == '-' then i = i + 1 end
		while i <= #s and s:sub(i, i):match('[%d%.eE%+%-]') do i = i + 1 end
		return tonumber(s:sub(start, i - 1))
	end
	local function parse_object()
		i = i + 1
		local obj = {}
		skip()
		if s:sub(i, i) == '}' then i = i + 1 return obj end
		while true do
			skip()
			if s:sub(i, i) ~= '"' then err('expected key') end
			local k = parse_string()
			skip()
			if s:sub(i, i) ~= ':' then err('expected :') end
			i = i + 1
			obj[k] = parse_value()
			skip()
			local c = s:sub(i, i)
			if c == ',' then
				i = i + 1
			elseif c == '}' then
				i = i + 1
				return obj
			else
				err('expected , or }')
			end
		end
	end
	local function parse_array()
		i = i + 1
		local arr = {}
		skip()
		if s:sub(i, i) == ']' then i = i + 1 return arr end
		while true do
			arr[#arr + 1] = parse_value()
			skip()
			local c = s:sub(i, i)
			if c == ',' then
				i = i + 1
			elseif c == ']' then
				i = i + 1
				return arr
			else
				err('expected , or ]')
			end
		end
	end
	parse_value = function()
		skip()
		local c = s:sub(i, i)
		if c == '{' then return parse_object() end
		if c == '[' then return parse_array() end
		if c == '"' then return parse_string() end
		if c == 't' then i = i + 4 return true end
		if c == 'f' then i = i + 5 return false end
		if c == 'n' then i = i + 4 return nil end
		return parse_number()
	end
	return parse_value()
end

-- ---------- require 覆盖 ----------
local real_require = require

-- mkdir 由驱动注入真实实现（否则文件写不进去，测试会假失败）
M.mkdir_hook = nil

local lfs_mock = {
	attributes = function(p)
		-- os.rename 到自身：存在则成功（fopen 对目录在 Windows 上不可靠）
		local ok = os.rename(p, p)
		if ok then return { mode = 'directory' } end
		return nil
	end,
	mkdir = function(p)
		if M.mkdir_hook then M.mkdir_hook(p) end
		return 0
	end,
}

require = function(name)
	if name == 'json' then return json end
	if name == 'lfs' then return lfs_mock end
	return real_require(name)
end

-- ---------- 输入序列 / 键盘码 ----------
M.codes = {
	KEYCODE_UP = 1, KEYCODE_DOWN = 2, KEYCODE_LEFT = 3, KEYCODE_RIGHT = 4,
	KEYCODE_LEFTCONTROL = 10, KEYCODE_LEFTALT = 11, KEYCODE_SPACE = 12,
	KEYCODE_A = 20, KEYCODE_S = 21, KEYCODE_D = 22, KEYCODE_W = 23,
	KEYCODE_ENTER = 30, KEYCODE_1 = 31,
}
M.code_names = {
	[1] = 'Up', [2] = 'Down', [3] = 'Left', [4] = 'Right',
	[10] = 'Left Ctrl', [11] = 'Left Alt', [12] = 'Space',
	[20] = 'A', [21] = 'S', [22] = 'D', [23] = 'W',
	[30] = 'Enter', [31] = '1',
}

function M.make_seq(tokens)
	if tokens == nil or tokens == '' then
		return { tokens = '', empty = true }
	end
	return { tokens = tokens, empty = false }
end

-- ---------- 字段 / 端口 / ioport / input ----------
function M.make_field(name, ty, player, tokens, opts)
	opts = opts or {}
	local f = {
		name = name,
		type = ty,
		player = player or 0,
		mask = opts.mask or 1,
		defvalue = opts.defvalue or 0,
		is_analog = opts.is_analog or false,
		enabled = (opts.enabled ~= false),
		type_class = opts.type_class or 'controller',
		_tokens = tokens,
	}
	function f:input_seq(port) return M.make_seq(self._tokens) end
	function f:default_input_seq(port) return M.make_seq(self._tokens) end
	function f:set_value(v)
		M.calls.set_value[#M.calls.set_value + 1] = { name = self.name, v = v }
	end
	function f:clear_value()
		M.calls.clear_value[#M.calls.clear_value + 1] = { name = self.name }
	end
	return f
end

M.input = {
	seq_to_tokens = function(self, seq)
		if not seq then return '' end
		return seq.tokens or ''
	end,
	code_from_token = function(self, tok)
		return M.codes[tostring(tok):upper()] or 0
	end,
	code_name = function(self, code)
		return M.code_names[code] or ''
	end,
}

M.ioport = {
	ports = {},
	types = {},
	type_seq = function(self, ty, pl) return M.make_seq(nil) end,
}

-- ---------- 场景：2 人游戏，P1 4方向+3按钮(+1个无绑定)，P2 4方向+3按钮 ----------
function M.setup_game()
	M.reset_calls()
	local p1 = { fields = {} }
	local p2 = { fields = {} }

	p1.fields['P1_JOYSTICK_UP'] = M.make_field('P1_JOYSTICK_UP', 47, 0, 'KEYCODE_UP')
	p1.fields['P1_JOYSTICK_DOWN'] = M.make_field('P1_JOYSTICK_DOWN', 48, 0, 'KEYCODE_DOWN')
	p1.fields['P1_JOYSTICK_LEFT'] = M.make_field('P1_JOYSTICK_LEFT', 49, 0, 'KEYCODE_LEFT')
	p1.fields['P1_JOYSTICK_RIGHT'] = M.make_field('P1_JOYSTICK_RIGHT', 50, 0, 'KEYCODE_RIGHT')
	-- 混合绑定：手柄优先于键盘
	p1.fields['P1 Button 1'] = M.make_field('P1 Button 1', 60, 0, 'KEYCODE_LEFTCONTROL OR JOYCODE_1_BUTTON3')
	p1.fields['P1 Button 2'] = M.make_field('P1 Button 2', 61, 0, 'KEYCODE_LEFTALT')
	p1.fields['P1 Button 3'] = M.make_field('P1 Button 3', 62, 0, 'KEYCODE_SPACE')
	-- 无绑定：不应出现在菜单里
	p1.fields['P1 Button 4'] = M.make_field('P1 Button 4', 63, 0, nil)

	p2.fields['P2_JOYSTICK_UP'] = M.make_field('P2_JOYSTICK_UP', 47, 1, 'KEYCODE_W')
	p2.fields['P2_JOYSTICK_DOWN'] = M.make_field('P2_JOYSTICK_DOWN', 48, 1, 'KEYCODE_S')
	p2.fields['P2_JOYSTICK_LEFT'] = M.make_field('P2_JOYSTICK_LEFT', 49, 1, 'KEYCODE_A')
	p2.fields['P2_JOYSTICK_RIGHT'] = M.make_field('P2_JOYSTICK_RIGHT', 50, 1, 'KEYCODE_D')
	p2.fields['P2 Button 1'] = M.make_field('P2 Button 1', 60, 1, 'KEYCODE_ENTER')
	p2.fields['P2 Button 2'] = M.make_field('P2 Button 2', 61, 1, 'JOYCODE_2_BUTTON1')
	p2.fields['P2 Button 3'] = M.make_field('P2 Button 3', 62, 1, nil)

	M.ioport.ports = { P1 = p1, P2 = p2 }
end

-- ---------- manager / emu / _p ----------
M.manager = {
	machine = { ioport = M.ioport, input = M.input },
	options = {
		entries = {
			homepath = {
				value = function(self) return M.homepath .. ';0;0' end,
			},
		},
	},
}

M.emu = {
	register_prestart = function(cb)
		M.prestart_cb = cb
		return { dispose = function() end }
	end,
	add_machine_frame_notifier = function(cb)
		M.frame_cb = cb
		return { dispose = function() end }
	end,
	add_machine_stop_notifier = function(cb)
		M.stop_cb = cb
		return { dispose = function() end }
	end,
	register_menu = function(cb, populate, title)
		M.menu_cb = cb
		M.menu_items = populate
		M.menu_title = title
		M.calls.menu_registered = M.calls.menu_registered + 1
		return { dispose = function() end }
	end,
	print_info = function(s) M.calls.info[#M.calls.info + 1] = tostring(s) end,
	print_verbose = function(s) M.calls.verbose[#M.calls.verbose + 1] = tostring(s) end,
	print_error = function(s) M.calls.error[#M.calls.error + 1] = tostring(s) end,
	romname = function() return M.rom end,
}

function _p(key, def) return def or key end

-- 供测试驱动使用
function LOAD_PLUGIN(source)
	local chunk, err = load(source, 'init.lua', 't')
	if not chunk then error('load 失败: ' .. tostring(err)) end
	return chunk()
end

-- 分发到全局，供 init.lua 查找
emu = M.emu
manager = M.manager

MOCK = M
return M
