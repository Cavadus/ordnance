-- @@ORDNANCE@@ ordnance-loader-1
-- Ordnance starts Lua mods. One boot, plain Lua 5.1, no ffi.
-- It runs scripts declared the way Chef, Rat, and Boot Mod Loader find them:
--   -- HD2-Addon: mods/<author>/<name>
--   -- HD2-Boot: mods/<author>/<name>
--   -- HD2-Guest-Boot: <name>
--   -- HD2-Options: mods/<author>/<name>
-- A line `-- @loader rat` does not change that. The mod still starts.
-- File swaps are already on disk. This script does not copy .dl_bin files.
-- F10 opens the options menu: each mod's toggles, choices, sliders, and key
-- bindings. The key can be changed in that menu. F9 is not used.

local L = {}
local hd2rt_dispatch
local after_startup = {}
local on_shutdown = {}
local log_lines = {}
local log_path = nil

do
  local ok, dir = pcall(os.getenv, "APPDATA")
  if ok and type(dir) == "string" and dir ~= "" then
    log_path = dir .. "\\Arrowhead\\Helldivers2\\ordnance_loader.log"
  end
end

local function say(text)
  log_lines[#log_lines + 1] = os.date("%H:%M:%S ") .. tostring(text)
end

local function flush()
  if log_path == nil or #log_lines == 0 then return end
  local text = table.concat(log_lines, "\n") .. "\n"
  log_lines = {}
  local ok, file = pcall(io.open, log_path, "a")
  if ok and file ~= nil then
    pcall(function() file:write(text) file:close() end)
  end
end

say("== ordnance-loader-1 " .. os.date("%Y-%m-%d %H:%M:%S") .. " (" .. tostring(_VERSION) .. ")")
flush()

-- The engine does not call this file. The game's own boot bytecode registers
-- init, update, and render. Without that, the call goes to address 0 and the
-- process dies at the splash. Same bytecode Boot Mod Loader runs first.
local GAME_BOOT = "\27\76\117\97\81\0\1\4\4\4\8\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\2\3\27\0\0\0\36\0\0\0\7\0\0\0\36\64\0\0\7\64\0\0\36\128\0\0\7\128\0\0\36\192\0\0\7\192\0\0\5\0\1\0\6\64\65\0\6\128\65\0\28\128\128\0\87\192\65\0\22\128\0\128\5\0\2\0\65\64\2\0\28\64\0\1\5\128\2\0\69\192\2\0\133\0\3\0\28\128\128\1\26\0\0\0\22\128\0\128\5\0\3\0\6\64\67\0\28\64\128\0\30\0\128\0\14\0\0\0\4\5\0\0\0\105\110\105\116\0\4\9\0\0\0\115\104\117\116\100\111\119\110\0\4\7\0\0\0\117\112\100\97\116\101\0\4\7\0\0\0\114\101\110\100\101\114\0\4\9\0\0\0\115\116\105\110\103\114\97\121\0\4\12\0\0\0\65\112\112\108\105\99\97\116\105\111\110\0\4\6\0\0\0\98\117\105\108\100\0\4\8\0\0\0\114\101\108\101\97\115\101\0\4\8\0\0\0\114\101\113\117\105\114\101\0\4\6\0\0\0\100\101\98\117\103\0\4\7\0\0\0\114\97\119\103\101\116\0\4\3\0\0\0\95\71\0\4\4\0\0\0\106\105\116\0\4\4\0\0\0\111\102\102\0\4\0\0\0\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\2\1\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\6\0\0\0\6\0\0\0\0\0\0\2\1\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\7\0\0\0\7\0\0\0\0\1\0\2\1\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\8\0\0\0\8\0\0\0\0\0\0\2\1\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"            -- the game's boot bytecode, the one Boot Mod Loader runs first
do
  local ok, chunk, err = pcall(loadstring, GAME_BOOT, "=boot")
  if ok and type(chunk) == "function" then
    local ran, why = pcall(chunk)
    say("game boot: " .. (ran and "ran" or ("FAILED: " .. tostring(why))))
  else
    say("game boot: could not load: " .. tostring(ok and err or chunk))
  end
  flush()
end


local LUA_TYPE = "a14e8dfa2cd117e2"
local ARCHIVE = "9ba626afa44a3aa3"
local MAX_PATCH = 512
local GAP = 64

local function u32(s, at)
  local a, b, c, d = string.byte(s, at + 1, at + 4)
  if a == nil then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(s, at)
  local lo, hi = u32(s, at), u32(s, at + 4)
  if lo == nil or hi == nil then return nil end
  return lo + hi * 4294967296
end

local function hex64(s, at)
  local parts = {}
  for i = 8, 1, -1 do
    local b = string.byte(s, at + i)
    if b == nil then return nil end
    parts[#parts + 1] = string.format("%02x", b)
  end
  return table.concat(parts)
end

local function data_dir()
  local path = type(package) == "table" and package.path or ""
  for entry in string.gmatch(path, "[^;]+") do
    local game = string.match(entry, "^(.-)[\\/]bin[\\/]lua[\\/]%?%.lua$")
    if game ~= nil and game ~= "" and game ~= "." then
      local sep = string.find(game, "/", 1, true) and not string.find(game, "\\", 1, true) and "/" or "\\"
      return game .. sep .. "data", sep
    end
  end
  return nil, "\\"
end

local function declared_name(source)
  local line = string.match(source, "^([^\r\n]*)")
  if line == nil then return nil, nil end
  local addon = string.match(line, "^%-%- HD2%-Addon: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)%s*$")
  if addon ~= nil and string.sub(addon, -1) ~= "/" then return "addon", addon end
  local boot = string.match(line, "^%-%- HD2%-Boot: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)%s*$")
  if boot ~= nil then return "boot", boot end
  local guest = string.match(line, "^%-%- HD2%-Guest%-Boot: (%S+)%s*$")
  if guest ~= nil then return "guest", guest end
  local options = string.match(line, "^%-%- HD2%-Options: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)%s*$")
  if options ~= nil then return "options", options end
  return nil, nil
end

local function declared_in(file)
  local head = file:read(0x48)
  if head == nil or #head < 0x48 or u32(head, 0) ~= 0xF0000011 then return nil end
  local types, count = u32(head, 4), u32(head, 8)
  if types == nil or count == nil or count == 0 or count > 100000 or types > 1000 then return {} end
  file:seek("set", 0x48 + types * 32)
  local rows = file:read(count * 80)
  if rows == nil or #rows < count * 80 then return nil end
  local found = {}
  for i = 0, count - 1 do
    local row = i * 80
    if hex64(rows, row + 8) == LUA_TYPE then
      local at, size = u64(rows, row + 16), u32(rows, row + 56)
      if at ~= nil and size ~= nil and size > 8 then
        file:seek("set", at)
        local first = file:read(math.min(size, 8 + 400))
        if first ~= nil and #first > 8 and u32(first, 4) == 2 then
          local kind, name = declared_name(string.sub(first, 9))
          if kind ~= nil then
            found[#found + 1] = { kind = kind, name = name, at = at + 8, size = u32(first, 0) }
          end
        end
      end
    end
  end
  return found
end

local function discover()
  local dir, sep = data_dir()
  if dir == nil then
    say("no game folder in package.path")
    return {}, {}, {}
  end
  local addons, guests, options = {}, {}, {}
  local by_name, last_found, opened = {}, -1, 0
  for n = 0, MAX_PATCH do
    if n - last_found > GAP then break end
    local path = dir .. sep .. ARCHIVE .. ".patch_" .. n
    local ok, file = pcall(io.open, path, "rb")
    if ok and file ~= nil then
      last_found, opened = n, opened + 1
      local ok2, found = pcall(declared_in, file)
      if ok2 and type(found) == "table" then
        for _, entry in ipairs(found) do
          entry.patch, entry.path = n, path
          -- Several option files share one mod name. Each one is a piece
          -- the loader merges (ledger, weapons, a range). The last copy
          -- must not throw the rest away.
          if entry.kind == "options" then
            options[#options + 1] = entry
          else
            by_name[entry.kind .. ":" .. entry.name] = entry
          end
        end
      end
      pcall(function() file:close() end)
    end
  end
  for _, entry in pairs(by_name) do
    if entry.kind == "guest" or entry.kind == "boot" then guests[#guests + 1] = entry
    else addons[#addons + 1] = entry end
  end
  local function order(a, b)
    if a.patch ~= b.patch then return a.patch < b.patch end
    return a.name < b.name
  end
  table.sort(addons, order)
  table.sort(guests, order)
  table.sort(options, order)
  say(string.format("%s: %d patch archives, %d addons, %d boot scripts, %d option files",
    dir, opened, #addons, #guests, #options))
  return addons, guests, options
end

if rawget(_G, "CowboyBingusModLoader") == nil then
  local log_dir = nil
  do
    local ok, dir = pcall(os.getenv, "APPDATA")
    if ok and type(dir) == "string" and dir ~= "" then log_dir = dir .. "\\Arrowhead\\Helldivers2" end
  end
  rawset(_G, "CowboyBingusModLoader", {
    api = 1,
    revision = "ordnance-loader-1",
    capabilities = { ffi = false, io = true },
    open_log = function(name)
      if log_dir == nil then return nil end
      local safe = string.gsub(tostring(name), "[^%w_%-]", "_")
      local ok, file = pcall(io.open, log_dir .. "\\" .. safe .. ".log", "a")
      if ok then return file end
      return nil
    end,
    after_startup = function(fn)
      if type(fn) == "function" then after_startup[#after_startup + 1] = fn end
    end,
    on_shutdown = function(fn)
      if type(fn) == "function" then on_shutdown[#on_shutdown + 1] = fn end
    end,
  })
end

local menu_api

-- The game's own scripts keep the Keyboard functions they find at init.
-- Wrap those before init runs, or a later swap never reaches them.
local raw_input = {}

local function install_input_gate()
  if raw_input.ready then return end
  local S = rawget(_G, "stingray")
  local K = type(S) == "table" and S.Keyboard or nil
  if type(K) ~= "table" or type(K.pressed) ~= "function" then return end
  local function blocked()
    return menu_api ~= nil and type(menu_api.blocking) == "function" and menu_api.blocking()
  end
  local function wrap(name, quiet)
    local orig = K[name]
    if type(orig) ~= "function" then return end
    raw_input[name] = orig
    K[name] = function(...)
      if blocked() then return quiet end
      return orig(...)
    end
  end
  wrap("pressed", false)
  wrap("released", false)
  wrap("any_pressed", false)
  wrap("any_released", false)
  wrap("button", 0)
  local keys = K.keystrokes
  if type(keys) == "function" then
    raw_input.keystrokes = keys
    K.keystrokes = function(...)
      if blocked() then return {} end
      return keys(...)
    end
  end
  raw_input.ready = true
  say("input gate installed")
end

-- A mod that never returns is stopped. The hook counts Lua instructions and
-- only while one of our calls into a mod is running. A long gap is the engine,
-- not a loop, and does not count. The first time the limit passes is only a
-- mark: the next million instructions means it is still in Lua.
local dog = { owner = false, stack = {} }

local function dog_now()
  if type(os) ~= "table" or type(os.clock) ~= "function" then return nil end
  local ok, t = pcall(os.clock)
  if ok and type(t) == "number" then return t end
  return nil
end

local function dog_enter(name, limit)
  local now = dog_now()
  dog.stack[#dog.stack + 1] = {
    owner = dog.owner, since = dog.since, skew = dog.skew, tick = dog.tick,
    over = dog.over, limit = dog.limit,
  }
  if now == nil then return end
  dog.owner, dog.since, dog.skew, dog.tick, dog.over, dog.limit = name, now, 0, now, false, limit or 3
end

local function dog_leave()
  local prev = dog.stack[#dog.stack]
  dog.stack[#dog.stack] = nil
  if prev == nil then dog.owner = false return end
  dog.owner, dog.since, dog.skew, dog.tick, dog.over, dog.limit =
    prev.owner, prev.since, prev.skew, prev.tick, prev.over, prev.limit
end

local function dog_arm()
  if dog.hook then return end
  if type(debug) ~= "table" or type(debug.sethook) ~= "function" or type(debug.gethook) ~= "function" then
    say("hang watchdog off: this Lua has no debug hook")
    return
  end
  local prev = debug.gethook()
  if type(prev) == "function" then
    say("hang watchdog off: another hook is already set")
    return
  end
  local function hook()
    if not dog.owner then return end
    local now = dog_now()
    if now == nil then return end
    local gap = now - dog.tick
    dog.tick = now
    if gap > 0.5 then dog.skew = dog.skew + gap end
    if (now - dog.skew) - dog.since <= dog.limit then return end
    if not dog.over then dog.over = true return end
    error("ordnance stopped " .. tostring(dog.owner) .. ": it ran too long", 2)
  end
  dog.hook = hook
  debug.sethook(hook, "", 1000000)
  say("hang watchdog on")
end

local function dog_disarm()
  dog.owner = false
  dog.stack = {}
  if type(debug) ~= "table" or type(debug.sethook) ~= "function" then return end
  if dog.hook and type(debug.gethook) == "function" and debug.gethook() == dog.hook then
    debug.sethook()
  end
  dog.hook = nil
end

-- Options menu. Mods receive their own chef table (local chef = ...).
-- The menu calls are here, and so are the world and draw calls a mod needs
-- to put something on screen. Anything else logs and returns nil.
menu_api = (function()
  local settings, groups, group_of, rows = {}, {}, {}, {}
  local open, selected, scroll, capture = false, 1, 0, nil
  local gui, gui_world, drawn, draw_failed = nil, nil, {}, false
  local boxes = {}
  local screen_noted = false
  local key_ids = nil
  local mouse_was_down = false
  local held, index_of, just = {}, {}, {}
  local saved_input = nil
  local FONT = "core/performance_hud/debug"
  local NAV = { up = true, down = true, left = true, right = true, enter = true,
    ["return"] = true, esc = true, escape = true, backspace = true, tab = true }
  local PALETTE = { "FFFFFF", "FFE710", "FF9500", "FF3B30", "0A84FF", "34C759", "000000" }

  local function settings_path()
    local ok, dir = pcall(os.getenv, "APPDATA")
    if ok and type(dir) == "string" and dir ~= "" then
      return dir .. "\\Arrowhead\\Helldivers2\\ordnance_loader_settings.txt"
    end
    return nil
  end

  local function encode(v)
    local t = type(v)
    if t == "boolean" then return "b", v and "1" or "0" end
    if t == "number" then return "n", tostring(v) end
    return "s", string.gsub(tostring(v), "[\r\n\t]", " ")
  end

  local function decode(kind, data)
    if kind == "b" then return data == "1" end
    if kind == "n" then return tonumber(data) or 0 end
    return data
  end

  local SETTINGS_END = "-- end"

  local function read_settings_file(path)
    local ok, file = pcall(io.open, path, "r")
    if not ok or file == nil then return nil, false end
    local bag, closed = {}, false
    for line in file:lines() do
      if line == SETTINGS_END then closed = true
      else
        local owner, key, kind, data = string.match(line, "^([^\t]*)\t([^\t]*)\t([bns])\t(.*)$")
        if owner and key then
          bag[owner] = bag[owner] or {}
          bag[owner][key] = decode(kind, data)
        end
      end
    end
    pcall(function() file:close() end)
    return bag, closed
  end

  local function load_settings()
    local path = settings_path()
    if path == nil then return end
    -- A finished .tmp is a save that did not get renamed into place. It is
    -- newer than the file it was meant to replace. A .tmp with no end line
    -- was cut off and is ignored.
    local main = read_settings_file(path)
    local tmp, tmp_closed = read_settings_file(path .. ".tmp")
    local use = tmp_closed and tmp or main
    if type(use) ~= "table" then return end
    for owner, bag in pairs(use) do settings[owner] = bag end
  end

  local function save_settings()
    local path = settings_path()
    if path == nil then return end
    local lines = {}
    for owner, bag in pairs(settings) do
      for key, value in pairs(bag) do
        local kind, data = encode(value)
        lines[#lines + 1] = owner .. "\t" .. key .. "\t" .. kind .. "\t" .. data
      end
    end
    table.sort(lines)
    lines[#lines + 1] = SETTINGS_END
    local text = table.concat(lines, "\n") .. "\n"
    local tmp = path .. ".tmp"
    local function write_to(dest)
      local ok, file = pcall(io.open, dest, "w")
      if not ok or file == nil then return false end
      local wrote = false
      pcall(function() file:write(text) file:close() wrote = true end)
      return wrote
    end
    if not write_to(tmp) then return end
    pcall(os.remove, path)
    local renamed = false
    pcall(function() renamed = os.rename(tmp, path) == true end)
    if renamed then return end
    if write_to(path) then pcall(os.remove, tmp) end
  end

  local function stored(owner, key, default)
    local bag = settings[owner]
    if bag and bag[key] ~= nil then return bag[key] end
    return default
  end

  local function store(owner, key, value)
    settings[owner] = settings[owner] or {}
    if value == nil then settings[owner][key] = nil else settings[owner][key] = value end
    save_settings()
  end

  load_settings()

  local function stingray()
    local S = rawget(_G, "stingray")
    if type(S) ~= "table" then return nil end
    return S
  end

  local function key_index(name)
    if index_of[name] ~= nil then return index_of[name] end
    local S = stingray()
    local K = S and S.Keyboard
    index_of[name] = false
    if type(K) ~= "table" or type(K.button_index) ~= "function" then return false end
    local tries = { name, string.upper(name), string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2) }
    for i = 1, #tries do
      local ok, found = pcall(K.button_index, tries[i])
      if ok and found ~= nil then index_of[name] = found return found end
    end
    return false
  end

  local function read_button(i)
    local S = stingray()
    local K = S and S.Keyboard
    if type(K) ~= "table" or type(K.button) ~= "function" then return false end
    local fn = raw_input.button or (saved_input and saved_input.button) or K.button
    local ok, v = pcall(fn, i)
    if not ok then return false end
    return (type(v) == "number" and v > 0.5) or v == true
  end

  local function key_down(name)
    if type(name) ~= "string" or name == "" or name == "off" then return false end
    local i = key_index(name)
    if not i then return false end
    return read_button(i)
  end

  local function mod_down(which)
    if which == "ctrl" then return key_down("left ctrl") or key_down("right ctrl") or key_down("ctrl") end
    if which == "shift" then return key_down("left shift") or key_down("right shift") or key_down("shift") end
    if which == "alt" then return key_down("left alt") or key_down("right alt") or key_down("alt") end
    return false
  end

  local function is_mod(name)
    return name == "ctrl" or name == "shift" or name == "alt"
      or name == "left ctrl" or name == "right ctrl" or name == "left shift" or name == "right shift"
      or name == "left alt" or name == "right alt" or name == "left super" or name == "right super"
  end

  -- Named keys only. Walking every button index can fault inside the engine,
  -- and a Lua pcall does not catch that.
  local WATCH = {
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    "up", "down", "left", "right", "enter", "return", "escape", "esc", "backspace", "tab", "space",
    "left ctrl", "right ctrl", "ctrl", "left shift", "right shift", "shift", "left alt", "right alt", "alt",
  }
  for i = 0, 9 do WATCH[#WATCH + 1] = tostring(i) end
  for i = string.byte("a"), string.byte("z") do WATCH[#WATCH + 1] = string.char(i) end

  local function poll()
    just = {}
    for i = 1, #WATCH do
      local name = WATCH[i]
      local down = key_down(name)
      if down and not held[name] then just[name] = true end
      held[name] = down and true or nil
    end
  end

  local function binding_down(spec, edge)
    if type(spec) ~= "string" or spec == "" or spec == "off" then return false end
    local parts, key = {}, nil
    for part in string.gmatch(string.lower(spec), "[^+]+") do
      part = string.gsub(string.gsub(part, "^%s+", ""), "%s+$", "")
      if part ~= "" then parts[#parts + 1] = part end
    end
    if #parts == 0 then return false end
    key = parts[#parts]
    local need = {}
    for i = 1, #parts - 1 do need[parts[i]] = true end
    if edge then
      if not just[key] then return false end
    elseif not key_down(key) then
      return false
    end
    if need.ctrl and not mod_down("ctrl") then return false end
    if need.shift and not mod_down("shift") then return false end
    if need.alt and not mod_down("alt") then return false end
    return true
  end

  local function drain_keystrokes(fn)
    if type(fn) ~= "function" then return end
    for _ = 1, 8 do
      local ok, ev = pcall(fn)
      if not ok or type(ev) ~= "table" or next(ev) == nil then break end
    end
  end

  local function suppress(on)
    local S = stingray()
    local K = S and S.Keyboard
    if type(K) ~= "table" then return end
    if on and not saved_input then
      saved_input = { pressed = K.pressed, button = K.button, keystrokes = K.keystrokes }
      K.pressed = function() return false end
      K.button = function() return 0 end
      -- Empty list, not nil. Nil is what the chat box turned into a newline.
      if K.keystrokes ~= nil then K.keystrokes = function() return {} end end
    elseif not on and saved_input then
      drain_keystrokes(raw_input.keystrokes or saved_input.keystrokes)
      K.pressed, K.button, K.keystrokes = saved_input.pressed, saved_input.button, saved_input.keystrokes
      saved_input = nil
    end
  end

  local function group(owner, title)
    local g = group_of[owner]
    if not g then
      g = { owner = owner, title = title or owner, rows = {} }
      group_of[owner] = g
      groups[#groups + 1] = g
    elseif title and title ~= "" then
      g.title = title
    end
    return g
  end

  local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end

  local function clean(spec, value)
    local ty = spec.type
    if ty == "toggle" then return value == true end
    if ty == "button" then return false end
    if ty == "color" then
      local h = type(value) == "string" and string.match(value, "^#?(%x%x%x%x%x%x)$")
      return h and string.upper(h) or "FFFFFF"
    end
    if ty == "choice" then
      local n = #spec.choices
      local v = math.floor(tonumber(value) or 0)
      if v >= 1 and v <= n then return v end
      local d = math.floor(tonumber(spec.default) or 1)
      if d >= 1 and d <= n then return d end
      return 1
    end
    if ty == "slider" then
      local v = tonumber(value) or tonumber(spec.default) or spec.min
      if not finite(v) then v = spec.min end
      if v < spec.min then v = spec.min end
      if v > spec.max then v = spec.max end
      if spec.step and spec.step > 0 then
        v = spec.min + math.floor((v - spec.min) / spec.step + 0.5) * spec.step
      end
      if v < spec.min then v = spec.min end
      if v > spec.max then v = spec.max end
      return v
    end
    if ty == "key" then
      local k = type(value) == "string" and string.lower(value) or "off"
      if spec.menu and (k == "off" or NAV[k] or string.find(k, "+", 1, true)) then return "f10" end
      return k
    end
    return value
  end

  local function check_spec(spec)
    if type(spec) ~= "table" then return "the spec must be a table" end
    local ty = spec.type
    if ty ~= "toggle" and ty ~= "choice" and ty ~= "slider" and ty ~= "key" and ty ~= "button" and ty ~= "color" then
      return "type must be toggle, choice, slider, key, button or color"
    end
    if ty == "choice" and (type(spec.choices) ~= "table" or #spec.choices < 2) then return "a choice needs at least 2 choices" end
    if ty == "button" and spec.run ~= nil and type(spec.run) ~= "function" then return "a button's run is a function" end
    if ty == "slider" and not (finite(spec.min) and finite(spec.max) and spec.max > spec.min) then
      return "a slider needs min < max"
    end
    return nil
  end

  local function fire(row)
    for i = 1, #row.changed do
      dog_enter(row.owner .. " " .. row.id, 3)
      local ok, err = pcall(row.changed[i], row.value)
      dog_leave()
      if not ok then say(row.owner .. " option " .. row.id .. ": " .. tostring(err)) end
    end
  end

  local function set_value(row, value, notify)
    value = clean(row.spec, value)
    if value == row.value then return value end
    row.value = value
    local saved = value
    if value == row.default then saved = nil end
    store(row.owner, "opt." .. row.id, saved)
    if notify then fire(row) end
    return value
  end

  local function loose_id(id)
    return type(id) == "string" and id ~= "" and #id <= 96 and string.find(id, "%c") == nil
  end

  local function add_option(owner, id, spec, loose)
    if loose then
      if not loose_id(id) then return nil, "invalid id" end
    elseif type(id) ~= "string" or string.match(id, "^[%w_%.%-]+$") == nil then
      return nil, "ids are letters, digits, _ . -"
    end
    local err = check_spec(spec)
    if err then return nil, err end
    local full = owner .. "|" .. id
    if rows[full] then return rows[full] end
    local row = { owner = owner, id = id, spec = spec, changed = {} }
    row.default = clean(spec, spec.default)
    row.value = clean(spec, stored(owner, "opt." .. id, row.default))
    rows[full] = row
    local g = group(owner, spec._title)
    g.rows[#g.rows + 1] = row
    return row
  end

  local function show(row)
    local ty = row.spec.type
    if capture == row then return "press a key" end
    if ty == "toggle" then if row.value then return "on" else return "off" end end
    if ty == "choice" then
      local c = row.spec.choices[row.value]
      if c == nil then return "?" end
      return tostring(c)
    end
    if ty == "slider" then return string.format("%.4g", row.value) end
    if ty == "button" then return row.spec.text or "run" end
    if ty == "color" then return row.value end
    return tostring(row.value)
  end

  local function lines()
    local out = {}
    for i = 1, #groups do
      local g = groups[i]
      out[#out + 1] = { kind = "title", title = g.title }
      local sub = false
      for j = 1, #g.rows do
        local row = g.rows[j]
        local heading = row.spec.heading
        if type(heading) == "string" and heading ~= "" then
          sub = row.spec.sub == true
          out[#out + 1] = { kind = "heading", title = heading, sub = sub }
        end
        out[#out + 1] = { kind = "row", row = row, sub = sub }
      end
    end
    return out
  end

  local function move(dir)
    local list = lines()
    if #list == 0 then return end
    local i = selected
    for _ = 1, #list do
      i = i + dir
      if i < 1 then i = #list end
      if i > #list then i = 1 end
      if list[i].kind == "row" then selected = i return end
    end
  end

  local function nudge(row, dir)
    local ty = row.spec.type
    if ty == "toggle" then set_value(row, not row.value, true) return end
    if ty == "choice" then
      local n = #row.spec.choices
      local v = row.value + dir
      if v < 1 then v = n end
      if v > n then v = 1 end
      set_value(row, v, true)
      return
    end
    if ty == "slider" then
      local step = row.spec.step
      if not step or step <= 0 then step = (row.spec.max - row.spec.min) / 10 end
      set_value(row, row.value + dir * step, true)
      return
    end
    if ty == "color" then
      local palette = row.spec.palette or PALETTE
      local at = 1
      for i = 1, #palette do if string.upper(palette[i]) == row.value then at = i end end
      at = at + dir
      if at < 1 then at = #palette end
      if at > #palette then at = 1 end
      set_value(row, palette[at], true)
    end
  end

  local function menu_key()
    local row = rows["ordnance|menu_key"]
    if row and type(row.value) == "string" then return row.value end
    return "f10"
  end

  -- The names Keyboard.button_name actually uses. Built once; the headlamp
  -- mod does the same scan and the game keeps running.
  local function ensure_key_ids()
    if key_ids then return key_ids end
    local S = stingray()
    local K = S and S.Keyboard
    if type(K) ~= "table" or type(K.button_name) ~= "function" then return nil end
    local map = {}
    for id = 0, 511 do
      local ok, name = pcall(K.button_name, id)
      if ok and type(name) == "string" and name ~= "" then
        local lower = string.lower(name)
        if map[lower] == nil then map[lower] = id end
      end
    end
    key_ids = map
    return map
  end

  local NAV_NAMES = {
    "up", "down", "left", "right",
    "up arrow", "down arrow", "left arrow", "right arrow",
    "arrow up", "arrow down", "arrow left", "arrow right",
    "enter", "return", "numpad enter", "escape", "esc", "backspace",
  }

  -- Only the keys the menu needs. Asking every button, every frame, stalls the game.
  local function pressed_names()
    local map = ensure_key_ids()
    local S = stingray()
    local K = S and S.Keyboard
    local fn = raw_input.pressed or (saved_input and saved_input.pressed) or (K and K.pressed)
    if type(fn) ~= "function" then return {} end
    local out = {}
    for i = 1, #NAV_NAMES do
      local name = NAV_NAMES[i]
      local id = map and map[name]
      if id == nil then id = key_index(name) end
      if id then
        local ok, down = pcall(fn, id)
        if ok and (down == true or down == 1) then out[#out + 1] = name end
      end
    end
    return out
  end

  local function command_for(name)
    if name == "up" or name == "up arrow" or name == "arrow up" or name == "cursor up" then return "up" end
    if name == "down" or name == "down arrow" or name == "arrow down" or name == "cursor down" then return "down" end
    if name == "left" or name == "left arrow" or name == "arrow left" or name == "cursor left" then return "left" end
    if name == "right" or name == "right arrow" or name == "arrow right" or name == "cursor right" then return "right" end
    if name == "enter" or name == "return" or name == "numpad enter" then return "enter" end
    if name == "escape" or name == "esc" then return "close" end
    if name == "backspace" then return "back" end
    return nil
  end

  local function activate(row)
    if not row then return end
    local ty = row.spec.type
    if ty == "key" then capture = row
    elseif ty == "button" and type(row.spec.run) == "function" then
      local ok, err = pcall(row.spec.run)
      if not ok then say(row.owner .. " button " .. row.id .. ": " .. tostring(err)) end
    elseif ty == "toggle" or ty == "choice" or ty == "slider" or ty == "color" then
      nudge(row, 1)
    end
  end

  local function cursor_xy(S)
    local M = S and S.Mouse
    if type(M) ~= "table" or type(M.axis_index) ~= "function" or type(M.axis) ~= "function" then return nil end
    local ok, idx = pcall(M.axis_index, "cursor")
    if not ok or idx == nil then return nil end
    local ok2, v = pcall(M.axis, idx)
    if not ok2 or v == nil or type(S.Vector3) ~= "table" or type(S.Vector3.to_elements) ~= "function" then return nil end
    local ok3, x, y = pcall(S.Vector3.to_elements, v)
    if ok3 and type(x) == "number" and type(y) == "number" then return x, y end
    return nil
  end

  local function mouse_click(S)
    local M = S and S.Mouse
    if type(M) ~= "table" or type(M.button_index) ~= "function" or type(M.button) ~= "function" then return false end
    local ok, idx = pcall(M.button_index, "left")
    if not ok or idx == nil then return false end
    local ok2, v = pcall(M.button, idx)
    local down = ok2 and ((type(v) == "number" and v > 0.5) or v == true)
    local click = down and not mouse_was_down
    mouse_was_down = down and true or false
    return click
  end

  local function combo_from(keyname)
    local mods = {}
    if mod_down("ctrl") then mods[#mods + 1] = "ctrl" end
    if mod_down("shift") then mods[#mods + 1] = "shift" end
    if mod_down("alt") then mods[#mods + 1] = "alt" end
    if #mods == 0 then return keyname end
    return table.concat(mods, "+") .. "+" .. keyname
  end

  local menu_frame = 0
  local nav_held = {}
  local runtime
  local menu_was = false
  local function update(dt)
    menu_frame = menu_frame + 1
    poll()
    if runtime then runtime.drive("update", dt) end
    if capture then
      for name in pairs(just) do
        if name == "esc" or name == "escape" then
          capture = nil
        elseif name == "backspace" then
          if not capture.spec.menu then set_value(capture, "off", true) end
          capture = nil
        elseif not is_mod(name) then
          local bound = combo_from(name)
          if capture.spec.menu and (NAV[name] or string.find(bound, "+", 1, true)) then
            say("menu key stays a single key, not " .. bound)
          else
            set_value(capture, bound, true)
          end
          capture = nil
        end
      end
      suppress(true)
      return
    end
    if binding_down(menu_key(), true) then
      open = not open
      if open then
        local list = lines()
        if not (list[selected] and list[selected].kind == "row") then
          for i = 1, #list do
            if list[i].kind == "row" then selected = i break end
          end
        end
      else
        capture = nil
        nav_held = {}
      end
      suppress(open)
      return
    end
    if not open then
      -- Keep the keys until the one that closed the menu is up, then throw
      -- away anything the chat box would type (Enter becomes a newline).
      local still = false
      for name in pairs(held) do still = true break end
      if not still then for _, name in ipairs(pressed_names()) do still = true break end end
      if not still then suppress(false) end
      return
    end
    local list = lines()
    if selected > #list then selected = #list end
    if selected < 1 then selected = 1 end
    local row = list[selected] and list[selected].row
    -- One command per press. The engine names an arrow both "down" and
    -- "down arrow", and acting on both jumped a row, which is the first row
    -- of the next section.
    local down, cmds = {}, {}
    for name in pairs(just) do down[name] = true end
    for _, name in ipairs(pressed_names()) do down[name] = true end
    for name in pairs(down) do
      if not nav_held[name] then
        local cmd = command_for(name)
        if cmd then cmds[cmd] = true end
      end
    end
    nav_held = down
    if cmds.up then move(-1) end
    if cmds.down then move(1) end
    -- Enter is the game's chat key. Nothing in Lua can swallow that press,
    -- so a key row rebinds with Right and Enter does not activate a row.
    if cmds.left and row and row.spec.type ~= "key" and row.spec.type ~= "button" then nudge(row, -1) end
    if cmds.right and row then
      if row.spec.type == "key" or row.spec.type == "button" then activate(row) else nudge(row, 1) end
    end
    if cmds.close then open, capture, nav_held = false, nil, {} end
    if cmds.back and row and row.spec.type == "key" and not row.spec.menu then set_value(row, "off", true) end
    local S = stingray()
    if S and mouse_click(S) then
      local x, y = cursor_xy(S)
      if x and y then
        for i = 1, #boxes do
          local b = boxes[i]
          if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            selected = b.index
            activate(b.row)
            break
          end
        end
      end
    end
    suppress(open)
    if open ~= menu_was then
      menu_was = open
      if runtime and runtime.emit then runtime.emit("menu", open) end
    end
  end

  local function color(S, a, r, g, b)
    if type(S.Color) ~= "function" then return nil end
    local ok, c = pcall(S.Color, a, r, g, b)
    if ok then return c end
    return nil
  end

  local function drop_gui()
    local S = stingray()
    if S and gui and type(S.Gui) == "table" then
      for i = 1, #drawn do
        local kind, id = drawn[i][1], drawn[i][2]
        if id ~= nil and type(S.Gui[kind]) == "function" then pcall(S.Gui[kind], gui, id) end
      end
    end
    drawn = {}
    if S and gui and gui_world and type(S.World) == "table" and type(S.World.destroy_gui) == "function" then
      pcall(S.World.destroy_gui, gui_world, gui)
    end
    gui, gui_world = nil, nil
  end

  local function release()
    if runtime then runtime.drive("shutdown") end
    open, capture = false, nil
    suppress(false)
    drop_gui()
  end

  local function render()
    if runtime then runtime.drive("render") end
    local S = stingray()
    if not open or draw_failed then
      -- A screen GUI left up while the game quits hangs the renderer. Drop it
      -- as soon as the menu is closed, while its world is still alive.
      if gui then drop_gui() end
      return
    end
    if not S or type(S.Application) ~= "table" or type(S.World) ~= "table" or type(S.Gui) ~= "table" then return end
    local A = S.Application
    local main
    if type(A.main_world) == "function" then
      local ok, w = pcall(A.main_world)
      if ok then main = w end
    end
    local world
    if type(A.worlds) == "function" then
      local ok, worlds = pcall(A.worlds)
      if ok and type(worlds) == "table" then
        for i = 1, #worlds do if worlds[i] ~= main then world = worlds[i] break end end
        if world == nil then world = worlds[1] end
      end
    end
    if world == nil then world = main end
    if world == nil then return end
    if gui ~= nil and gui_world ~= world then gui, gui_world, drawn = nil, nil, {} end
    if gui == nil then
      -- "scale", 1, 1 is the screen GUI the in-game overlays use. "immediate"
      -- took the frame and left a black window.
      local ok, g = pcall(S.World.create_screen_gui, world, "scale", 1, 1)
      if not ok or g == nil then
        draw_failed = true
        say("options menu: the game did not give a screen to draw on")
        return
      end
      gui, gui_world = g, world
    end
    for i = 1, #drawn do
      local kind, id = drawn[i][1], drawn[i][2]
      if id ~= nil and type(S.Gui[kind]) == "function" then pcall(S.Gui[kind], gui, id) end
    end
    drawn = {}
    local w, h, how = 1920, 1080, "default"
    if type(S.Gui.resolution) == "function" then
      local ok, rw, rh = pcall(S.Gui.resolution)
      if ok and type(rw) == "number" and type(rh) == "number" and rw > 200 and rh > 200 then w, h, how = rw, rh, "gui" end
    end
    if how == "default" and type(A.back_buffer_size) == "function" then
      local ok, bw, bh = pcall(A.back_buffer_size)
      if ok and type(bw) == "number" and type(bh) == "number" and bw > 200 and bh > 200 then w, h, how = bw, bh, "buffer" end
    end
    if not screen_noted then
      screen_noted = true
      say(string.format("menu screen %s %dx%d", how, w, h))
      flush()
    end
    local scale = math.min(w / 1920, h / 1080)
    if scale < 0.75 then scale = 0.75 end
    local list = lines()
    local window = 16
    if selected < scroll + 1 then scroll = selected - 1 end
    if selected > scroll + window then scroll = selected - window end
    if scroll < 0 then scroll = 0 end
    local shown = math.min(window, math.max(0, #list - scroll))
    local row_h = math.max(32, math.floor(34 * scale))
    local hint = nil
    local picked = list[selected]
    if picked and picked.kind == "row" and type(picked.row.spec.hint) == "string" and picked.row.spec.hint ~= "" then
      hint = picked.row.spec.hint
      if #hint > 90 then hint = string.sub(hint, 1, 87) .. "..." end
    end
    local panel_w = math.min(w - 80, math.max(640, math.floor(860 * scale)))
    local panel_h = row_h + shown * row_h + (hint and row_h or 0) + math.floor(16 * scale)
    local x = math.floor((w - panel_w) / 2)
    local bottom = math.floor((h - panel_h) / 2)
    local top = bottom + panel_h
    local bg = color(S, 210, 12, 14, 16)
    local fg = color(S, 255, 236, 232, 214)
    local dim = color(S, 255, 160, 156, 140)
    local hi = color(S, 255, 255, 196, 64)
    local function rect(px, py, pw, ph, c, layer)
      if c == nil then return end
      local ok, id = pcall(S.Gui.rect, gui, S.Vector3(px, py, layer), S.Vector2(pw, ph), c)
      if ok and id ~= nil then drawn[#drawn + 1] = { "destroy_rect", id } end
    end
    local function text(str, px, py, size, c)
      if c == nil then return end
      local ok, id = pcall(S.Gui.text, gui, tostring(str), FONT, size, FONT, S.Vector3(px, py, 50), c)
      if ok and id ~= nil then drawn[#drawn + 1] = { "destroy_text", id } end
    end
    boxes = {}
    rect(x, bottom, panel_w, panel_h, bg, 40)
    text("Ordnance    " .. string.upper(menu_key()) .. " closes    click or arrows    right rebinds", x + 16 * scale, top - row_h, math.floor(18 * scale), fg)
    for i = 1, shown do
      local item = list[scroll + i]
      local y = top - row_h - i * row_h
      if item.kind == "title" or item.kind == "heading" then
        local indent = (item.sub and 36 or 20) * scale
        local size = math.floor((item.sub and 16 or 18) * scale)
        text(item.title, x + indent, y, size, item.kind == "title" and hi or dim)
      else
        local mark = (scroll + i == selected) and "> " or "  "
        local label = item.row.spec.label or item.row.id
        local indent = (item.sub and 36 or 20) * scale
        if scroll + i == selected then rect(x + 8, y - 4, panel_w - 16, row_h, color(S, 50, 255, 196, 64), 41) end
        text(mark .. label, x + indent, y, math.floor(18 * scale), fg)
        text(show(item.row), x + panel_w - 220 * scale, y, math.floor(18 * scale), dim)
        boxes[#boxes + 1] = { x = x, y = y - 4, w = panel_w, h = row_h, index = scroll + i, row = item.row }
      end
    end
    if hint then text(hint, x + 16 * scale, bottom + 8 * scale, math.floor(16 * scale), dim) end
  end

  -- World, unit watch, and screen drawing for a mod that used to ask Chef.
  -- One table holds the state so this function stays under Lua's local limit.
  runtime = (function()
    local R = {
      frame = 0, t0 = os.clock(), stopped = false,
      modules = {}, watches = {}, mission_kinds = {},
      ui = {}, sizes = {}, ids = {}, names = {}, known = {}, edge = {}, said = {},
      icons = {}, top_icons = {},
      world = nil, world_n = 0, draw_n = 0, mission = false, mission_at = 0,
      jobs = {}, kinds = {}, notes = {}, made = {},
      shared = {}, subs = {}, timers = {}, exports = {}, roster = {}, holds = {},
      cam_unit = nil, cam_data = nil, cam_frame = -1, cam_list = nil, cam_i = 0, cam_retry = 0,
      gui = nil, gui_world = nil,
    }
    local UI_MAT, UI_SLOT = "e2d6ed90906c1e8b", "3aa8b87e00000000"
    local BAD_KIND = "46cab355bd8d4d37"

    local function once(key, msg)
      if R.said[key] then return end
      R.said[key] = true
      say(msg)
      flush()
    end

    local function main_world()
      local S = stingray()
      local A = S and S.Application
      if type(A) ~= "table" or type(A.main_world) ~= "function" then return nil end
      local ok, w = pcall(A.main_world)
      if ok and w ~= nil then return w end
      return nil
    end

    local function forget_draw()
      R.gui, R.gui_world, R.text = nil, nil, nil
      R.icons = {}
      R.top_w, R.top_n, R.top_gui, R.top_gui_world = nil, 0, nil, nil
      R.top_text, R.top_icons, R.top_frame = nil, {}, -1
      R.icon_ok = nil
    end

    local world_now

    local function world_clock(world)
      local S = stingray()
      if not S or type(S.World) ~= "table" or type(S.World.time) ~= "function" then return nil end
      local ok, t = pcall(S.World.time, world)
      if ok and type(t) == "number" then return t end
      return nil
    end

    local function id64(hex)
      if type(hex) ~= "string" then return nil end
      local hit = R.ids[hex]
      if hit ~= nil then return hit or nil end
      local S = stingray()
      local T = S and S.IdString64
      if type(T) ~= "table" or type(T.from_hex) ~= "function" then
        once("id64", "IdString64.from_hex is missing")
        return nil
      end
      local ok, id = pcall(T.from_hex, hex)
      if not ok or id == nil then return nil end
      R.ids[hex] = id
      return id
    end

    local function units_of(world, hex)
      local id = id64(hex)
      if not id then return nil, "no id" end
      local S = stingray()
      if type(S.World) ~= "table" or type(S.World.units_by_resource) ~= "function" then
        return nil, "no units_by_resource"
      end
      local ok, list = pcall(S.World.units_by_resource, world, id)
      if ok and type(list) == "table" then return list end
      return nil, ok and ("answered " .. type(list)) or list
    end

    local function alive(unit)
      local S = stingray()
      if type(S) ~= "table" or type(S.Unit) ~= "table" or type(S.Unit.alive) ~= "function" then return false end
      local ok, v = pcall(S.Unit.alive, unit)
      return ok and v == true
    end

    local function xyz(v)
      local S = stingray()
      local to_elements = S and S.Vector3 and S.Vector3.to_elements
      if v == nil or type(to_elements) ~= "function" then return nil end
      local ok, x, y, z = pcall(to_elements, v)
      if ok and type(x) == "number" then return x, y, z end
      return nil
    end

    local function vec3(x, y, z)
      local S = stingray()
      if not S or S.Vector3 == nil then return nil end
      local ok, v = pcall(S.Vector3, x, y, z)
      if ok then return v end
      return nil
    end

    local function vec2(x, y)
      local S = stingray()
      if not S or S.Vector2 == nil then return nil end
      local ok, v = pcall(S.Vector2, x, y)
      if ok then return v end
      return nil
    end

    local function pos_of(unit)
      local S = stingray()
      if type(S.Unit) ~= "table" or type(S.Unit.world_position) ~= "function" then return nil end
      local ok, p = pcall(S.Unit.world_position, unit, 1)
      if not ok then return nil end
      return xyz(p)
    end

    local function list_n(list)
      if type(list) ~= "table" then return 0 end
      local n = #list
      if n > 0 or list[1] == nil then return n end
      local i = 1
      while list[i] ~= nil and i < 100000 do i = i + 1 end
      return i - 1
    end

    local function scan(kinds)
      local world = world_now()
      if not world or type(kinds) ~= "table" then return {} end
      local out = {}
      for k in pairs(kinds) do
        if type(k) == "string" then
          local hex = string.lower(k)
          if #hex == 16 and string.match(hex, "^%x+$") and hex ~= BAD_KIND then
            local list, err = units_of(world, hex)
            if not list and err ~= "no id" then once("units", "units_by_resource: " .. tostring(err)) end
            local n = list_n(list)
            for i = 1, n do
              local u = list[i]
              if alive(u) then
                local x, y, z = pos_of(u)
                if x then out[#out + 1] = { unit = u, kind = hex, x = x, y = y, z = z } end
              end
            end
          end
        end
      end
      return out
    end

    -- Chef's split: more than 10 levels, or more than 5000 units when the
    -- level count is unavailable. The ship sits under that. Three of the
    -- mod's own loot units also count, once the world is big enough to search.
    local function measure_world(world)
      local S = stingray()
      local units, levels, units_ok = 0, nil, false
      if S and type(S.World) == "table" then
        if type(S.World.num_units) == "function" then
          local ok, n = pcall(S.World.num_units, world)
          if ok and type(n) == "number" then units, units_ok = n, true
          else once("num_units", "World.num_units: " .. tostring(n)) end
        else
          once("num_units", "World.num_units is missing")
        end
        if type(S.World.num_levels) == "function" then
          local ok, n = pcall(S.World.num_levels, world)
          if ok and type(n) == "number" then levels = n end
        end
      end
      return units, levels, units_ok
    end

    local function big_world(units, levels)
      if levels ~= nil and levels > 10 then return true end
      return units > 5000
    end

    -- Unit queries stay on the locked mission world. Screen GUIs follow
    -- Chef: the main world, and only after that same world has lasted 3
    -- seconds without its clock running backwards. A GUI is dropped, not
    -- destroyed, when its world has already left the list.
    local drop_draw

    local function worlds_now()
      if R.ws_frame == R.frame then return R.ws end
      R.ws_frame = R.frame
      R.ws = nil
      local S = stingray()
      local A = S and S.Application
      if type(A) == "table" and type(A.worlds) == "function" then
        local ok, ws = pcall(A.worlds)
        if ok and type(ws) == "table" then R.ws = ws end
      end
      return R.ws
    end

    local function world_listed(world)
      if world == nil then return false end
      local ws = worlds_now()
      if type(ws) ~= "table" then return false end
      for i = 1, #ws do
        if ws[i] == world then return true end
      end
      return false
    end

    drop_draw = function()
      local S = stingray()
      local kill = S and type(S.World) == "table" and S.World.destroy_gui
      local function bye(world, g)
        if g and g ~= false and type(kill) == "function" and world_listed(world) then
          pcall(kill, world, g)
        end
      end
      bye(R.gui_world, R.gui)
      if type(R.text) == "table" then bye(R.text.world, R.text.g) end
      for _, e in pairs(R.icons) do
        if type(e) == "table" then bye(e.world, e.gui) end
      end
      bye(R.top_gui_world, R.top_gui)
      if type(R.top_text) == "table" then bye(R.top_text.world, R.top_text.g) end
      for _, e in pairs(R.top_icons) do
        if type(e) == "table" then bye(e.world, e.gui) end
      end
      forget_draw()
    end

    -- A new main world retires unit handles, line objects, and walks a mod
    -- had going. Kept jobs (opts.keep) survive. Spawned units are not
    -- destroyed here: their world is already gone.
    R.forget_world = function()
      R.draw_n = (R.draw_n or 0) + 1
      R.kinds = {}
      R.lines, R.lines_used, R.lines_shown, R.lines_world = nil, false, false, nil
      local kept, jobs = {}, R.jobs
      if type(jobs) == "table" then
        for i = 1, #jobs do
          local j = jobs[i]
          if type(j) == "table" and j.keep and j.on then
            kept[#kept + 1] = j
          elseif type(j) == "table" and j.on and type(j.done) == "function" then
            j.on = false
            pcall(j.done, false)
          end
        end
      end
      R.jobs = kept
      R.made = {}
    end

    local function settle(world, now)
      if world == nil then return end
      if R.held ~= world then
        if R.held ~= nil then
          drop_draw()
          if now >= (R.moved_log or 0) then
            R.moved_log = now + 2
            say("draw world changed, waiting")
            flush()
          end
        end
        R.forget_world()
        R.held = world
        R.world_since = now
        R.stable = false
        R.world_time = nil
        R.time_at = 0
      end
      if now >= (R.time_at or 0) then
        R.time_at = now + 0.25
        local t = world_clock(world)
        if type(t) == "number" and type(R.world_time) == "number" and t < R.world_time then
          drop_draw()
          R.forget_world()
          R.held = world
          R.stable = false
          R.world_since = now
          say("draw world restarted")
          flush()
        end
        if type(t) == "number" then R.world_time = t end
      end
      if not R.stable and R.world_since and now - R.world_since >= 3 then
        R.stable = true
        once("stable", "draw world settled")
        if R.emit then R.emit("world", R.draw_n or 0) end
      end
    end

    world_now = function()
      local now = os.clock()
      -- Once a frame, same as Chef. Sampling main_world() on every draw
      -- call would see the short-lived world and throw the draw away.
      if R.settle_frame ~= R.frame then
        R.settle_frame = R.frame
        settle(main_world(), now)
      end
      if R.mission_world then
        if now < (R.hold_check or 0) then return R.mission_world end
        R.hold_check = now + 0.5
        local units, levels = measure_world(R.mission_world)
        if big_world(units, levels) or units > 1000 then return R.mission_world end
        R.mission_world = nil
        R.mission = false
        R.sized = false
        say("left the mission world (" .. units .. " units)")
        flush()
      end
      local main = main_world()
      if not main then return nil end
      local units, levels = measure_world(main)
      if big_world(units, levels) then
        if R.mission_world ~= main then
          R.mission_world = main
          R.world_n = R.world_n + 1
          R.sized = false
        end
        R.hold_check = now + 0.5
        return main
      end
      return main
    end

    local function in_mission()
      local world = world_now()
      if not world then return false end
      local now = os.clock()
      if R.sized and now < (R.stats_at or 0) then return R.mission == true end
      R.stats_at = now + 0.5
      local units, levels, units_ok = measure_world(world)
      local mission
      if levels ~= nil then mission = levels > 10
      else mission = units > 5000 end
      if not mission and (not units_ok or units >= 1000) then
        local found = 0
        for k in pairs(R.mission_kinds) do
          local list, err = units_of(world, k)
          if not list and err ~= nil and err ~= "no id" then
            once("units", "units_by_resource: " .. tostring(err))
          end
          found = found + list_n(list)
          if found >= 3 then mission = true; break end
        end
      end
      if mission ~= R.mission or not R.sized then
        R.sized = true
        R.mission = mission
        local extra = levels and (", " .. levels .. " levels") or ""
        say(string.format("world %d: %s (%d units%s)", R.world_n, mission and "mission" or "not a mission", units, extra))
        flush()
      end
      return mission
    end

    local function cam_from(unit)
      local S = stingray()
      if type(S.Unit) ~= "table" or type(S.Camera) ~= "table" then return nil end
      local ok, c = pcall(S.Unit.camera, unit, 1)
      if not ok or c == nil then return nil end
      local okp, p = pcall(S.Camera.world_position, c)
      if not okp then return nil end
      local x, y, z = xyz(p)
      if not x then return nil end
      local d = { x = x, y = y, z = z, fx = 0, fy = 1, fz = 0, cam = c }
      local okr, rot = pcall(S.Camera.world_rotation, c)
      if okr and rot ~= nil and type(S.Quaternion) == "table" and type(S.Quaternion.forward) == "function" then
        local okf, fwd = pcall(S.Quaternion.forward, rot)
        local fx, fy, fz = xyz(okf and fwd or nil)
        if fx then d.fx, d.fy, d.fz = fx, fy, fz end
      end
      return d
    end

    local function camera()
      if R.cam_frame == R.frame then return R.cam_data end
      R.cam_frame = R.frame
      R.cam_data = nil
      local world = world_now()
      local S = stingray()
      if not world or type(S) ~= "table" or type(S.Unit) ~= "table" then return nil end
      if R.cam_unit and alive(R.cam_unit) then
        R.cam_data = cam_from(R.cam_unit)
        if R.cam_data then return R.cam_data end
      end
      R.cam_unit = nil
      if os.clock() < R.cam_retry then return nil end
      if not R.cam_list then
        if type(S.World) ~= "table" or type(S.World.units) ~= "function" then return nil end
        local ok, units = pcall(S.World.units, world)
        if not ok or type(units) ~= "table" then R.cam_retry = os.clock() + 2 return nil end
        R.cam_list, R.cam_i = units, 0
      end
      local n = list_n(R.cam_list)
      local last = math.min(n, R.cam_i + 400)
      for i = R.cam_i + 1, last do
        local u = R.cam_list[i]
        if alive(u) then
          local ok, nc = pcall(S.Unit.num_cameras, u)
          if ok and type(nc) == "number" and nc > 0 then
            R.cam_unit, R.cam_list = u, nil
            R.cam_data = cam_from(u)
            if R.cam_data then once("cam", "camera found") end
            return R.cam_data
          end
        end
      end
      R.cam_i = last
      if last >= n then
        R.cam_list = nil
        R.cam_retry = os.clock() + 2
      end
      return nil
    end

    local function screen_wh()
      local S = stingray()
      local A = S and S.Application
      if type(A) == "table" and type(A.back_buffer_size) == "function" then
        local ok, a, b = pcall(A.back_buffer_size)
        if ok and type(a) == "number" and type(b) == "number" and a > 200 and b > 200 then return a, b end
      end
      if S and type(S.Gui) == "table" and type(S.Gui.resolution) == "function" then
        local ok, a, b = pcall(S.Gui.resolution)
        if ok and type(a) == "number" and type(b) == "number" and a > 200 and b > 200 then return a, b end
      end
      return 1920, 1080
    end

    -- Chef's three screen GUIs. The panel is immediate and names the
    -- performance-hud font and material. Text is a separate scale GUI.
    -- Each icon texture gets its own immediate GUI, and only after the
    -- material and the texture are loaded. Ids are made per call: a kept
    -- id can be reused by the engine and then the draw hits the wrong slot.
    local GUI_MAT = "core/performance_hud/gui"
    local TOP_FROM = 2000

    local function fresh_id(hex)
      if type(hex) ~= "string" then return nil end
      local S = stingray()
      local T = S and S.IdString64
      if type(T) ~= "table" or type(T.from_hex) ~= "function" then return nil end
      local ok, id = pcall(T.from_hex, hex)
      if ok and id ~= nil then return id end
      return nil
    end

    local function screen_gui(world, mode, a, b, c, d)
      local S = stingray()
      if world == nil or type(S) ~= "table" or type(S.World) ~= "table"
        or type(S.World.create_screen_gui) ~= "function" then
        return nil
      end
      local ok, g
      if a == nil then ok, g = pcall(S.World.create_screen_gui, world, mode)
      else ok, g = pcall(S.World.create_screen_gui, world, mode, a, b, c, d) end
      if ok and g ~= nil and g ~= false then return g end
      return nil
    end

    local function draw_world()
      if R.stable and R.held ~= nil then return R.held end
      return nil
    end

    local function panel_gui(world)
      if world == nil or R.gui == false then return nil end
      if R.gui and R.gui_world == world then return R.gui end
      local g = screen_gui(world, "immediate", "material", FONT, "material", GUI_MAT)
      if not g then
        R.gui = false
        once("gui-fail", "mod draw gui failed")
        return nil
      end
      R.gui, R.gui_world = g, world
      once("gui", "mod draw gui")
      return g
    end

    local function top_world()
      local main = draw_world()
      if main == nil then return nil end
      if R.top_frame == R.frame and R.top_main == main then return R.top_w end
      R.top_frame, R.top_main = R.frame, main
      local ws = worlds_now()
      local found, n = nil, 0
      if type(ws) == "table" then
        n = #ws
        for i = 1, n do
          if ws[i] ~= main then found = ws[i]; break end
        end
      end
      if R.top_w ~= nil and (found == nil or n ~= R.top_n or found ~= R.top_w) then
        R.top_w, R.top_n, R.top_gui, R.top_gui_world = nil, 0, nil, nil
        R.top_text, R.top_icons = nil, {}
      end
      if R.top_w == nil and found ~= nil then R.top_w, R.top_n = found, n end
      return R.top_w
    end

    local function top_gui()
      local w = top_world()
      if w == nil or R.top_gui == false then return nil end
      if R.top_gui and R.top_gui_world == w then return R.top_gui end
      local g = screen_gui(w, "immediate", "material", FONT, "material", GUI_MAT)
      if not g then
        R.top_gui = false
        once("top-gui", "top draw gui failed")
        return nil
      end
      R.top_gui, R.top_gui_world = g, w
      once("top-gui-ok", "top draw gui")
      return g
    end

    local function text_bucket(world, paired, which)
      local t = R[which]
      if type(t) == "table" and t.world == world and t.paired == paired then return t end
      if type(t) == "table" and t.g and world_listed(t.world) then
        local S = stingray()
        if S and type(S.World) == "table" and type(S.World.destroy_gui) == "function" then
          pcall(S.World.destroy_gui, t.world, t.g)
        end
      end
      local g = screen_gui(world, "scale", 1, 1)
      if not g then
        R[which] = nil
        once("text-gui", "mod text gui failed")
        return nil
      end
      t = { g = g, world = world, paired = paired, ids = {} }
      R[which] = t
      once("text-ok", "mod text gui")
      return t
    end

    local function wipe_text(t)
      if type(t) ~= "table" or type(t.ids) ~= "table" then return end
      local S = stingray()
      local fn = S and S.Gui and S.Gui.destroy_text
      if type(fn) == "function" then
        for i = 1, #t.ids do pcall(fn, t.g, t.ids[i]) end
      end
      t.ids = {}
    end

    local function rect(x, y, w, h, c, layer)
      if c == nil or not finite(x) or not finite(y) or not finite(w) or not finite(h) then return end
      if not R.stable then
        once("wait", "draw waits until the world has settled")
        return
      end
      layer = finite(layer) and layer or 900
      local g
      if layer >= TOP_FROM then
        g = top_gui()
        layer = layer - TOP_FROM
      else
        g = panel_gui(draw_world())
      end
      if not g then return end
      local S = stingray()
      if type(S) ~= "table" or type(S.Gui) ~= "table" or type(S.Gui.rect) ~= "function" then return end
      local p, s = vec3(x, y, layer), vec2(w, h)
      if not p or not s then return end
      pcall(S.Gui.rect, g, p, s, c)
    end

    local function text_width(str, px)
      return #tostring(str or "") * (tonumber(px) or 16) * 0.55
    end

    local function text(x, y, str, px, c, layer)
      if c == nil or not finite(x) or not finite(y) then return 0 end
      px = tonumber(px) or 16
      local wide = text_width(str, px)
      if not R.stable then
        once("wait", "draw waits until the world has settled")
        return wide
      end
      layer = finite(layer) and layer or 900
      local on_top = layer >= TOP_FROM
      local world, paired
      if on_top then
        paired = top_gui()
        world = R.top_w
        layer = layer - TOP_FROM
      else
        world = draw_world()
        paired = panel_gui(world)
      end
      if not paired or world == nil then return wide end
      local which = on_top and "top_text" or "text"
      local bucket = text_bucket(world, paired, which)
      local S = stingray()
      if not bucket or type(S) ~= "table" or type(S.Gui) ~= "table" or type(S.Gui.text) ~= "function" then
        return wide
      end
      local p = vec3(x, y, layer)
      if not p then return wide end
      local ok, id = pcall(S.Gui.text, bucket.g, tostring(str), FONT, px, FONT, p, c)
      if ok and id ~= nil then bucket.ids[#bucket.ids + 1] = id end
      return wide
    end

    local function sized(tex, w)
      local list = R.sizes[tex]
      if type(list) ~= "table" then return tex end
      local pick = nil
      for i = 1, #list, 2 do
        local width, id = list[i], list[i + 1]
        if type(width) == "number" and type(id) == "string" then
          pick = id
          if width >= w then return id end
        end
      end
      return pick or tex
    end

    local function bitmap(tex, x, y, w, h, c, layer, u0, v0, u1, v1)
      if type(tex) ~= "string" or c == nil or not finite(x) or not finite(y) or not finite(w) or not finite(h) then
        return false
      end
      if not R.stable then
        once("wait", "draw waits until the world has settled")
        return false
      end
      layer = finite(layer) and layer or 900
      tex = sized(tex, w)
      local icons, target = R.icons, draw_world()
      if layer >= TOP_FROM then
        target = top_world()
        icons = R.top_icons
        layer = layer - TOP_FROM
      end
      if target == nil or type(icons) ~= "table" then return false end
      local e = icons[tex]
      if e == false then return false end
      local S = stingray()
      local A = S and S.Application
      if e == nil then
        if R.icon_ok ~= true and os.clock() >= (R.icon_check or 0) then
          R.icon_check = os.clock() + 1
          local mid = fresh_id(UI_MAT)
          local yes = false
          if mid and type(A) == "table" and type(A.can_get) == "function" then
            local ok, got = pcall(A.can_get, "material", mid)
            yes = ok and got == true
          end
          R.icon_ok = yes
        end
        if R.icon_ok ~= true then
          once("icon-mat", "icons: the UI material is not loaded; the addon draws its own fallback")
          return false
        end
        local tid = fresh_id(tex)
        local ready = tid and type(A) == "table" and type(A.can_get) == "function"
        if ready then
          local ok, got = pcall(A.can_get, "texture", tid)
          ready = ok and got == true
        end
        if not ready then
          local alt = R.ui[tex]
          if type(alt) == "string" then
            local id2 = fresh_id(alt)
            if id2 and type(A) == "table" and type(A.can_get) == "function" then
              local ok2, got2 = pcall(A.can_get, "texture", id2)
              if ok2 and got2 == true then tex, ready = alt, true end
            end
          end
        end
        if not ready then
          once("icon-" .. tex, "icons: texture " .. tex .. " is not loaded; the addon draws its own fallback")
          return false
        end
        local g = screen_gui(target, "immediate")
        if not g then
          icons[tex] = false
          once("icon-gui", "icons: no screen GUI; the addon draws its own fallback")
          return false
        end
        e = { gui = g, world = target, frame = -1 }
        icons[tex] = e
        once("icon", "icon gui")
      end
      if type(e) ~= "table" then return false end
      if type(S) ~= "table" or type(S.Gui) ~= "table" then return false end
      if e.frame ~= R.frame then
        e.frame = R.frame
        local mat, slot, texid = fresh_id(UI_MAT), fresh_id(UI_SLOT), fresh_id(tex)
        local mh = nil
        if mat and type(S.Gui.material) == "function" then
          local okm, got = pcall(S.Gui.material, e.gui, mat)
          if okm then mh = got end
        end
        local bound = false
        if mh and slot and texid and type(S.Material) == "table" and type(S.Material.set_texture) == "function" then
          local oks, _, err = pcall(S.Material.set_texture, mh, slot, texid)
          bound = oks and type(err) ~= "string"
        end
        if not bound then
          icons[tex] = false
          once("icon-bind-" .. tex, "icons: texture " .. tex .. " refused")
          return false
        end
      end
      if type(S.Gui.bitmap) ~= "function" then return false end
      local mat = fresh_id(UI_MAT)
      local p, s = vec3(x, y, layer), vec2(w, h)
      if not mat or not p or not s then return false end
      local okb
      if u0 ~= nil and type(S.Gui.bitmap_uv) == "function" then
        local a0, a1 = vec2(u0, v0), vec2(u1, v1)
        if not (a0 and a1) then return false end
        okb = pcall(S.Gui.bitmap_uv, e.gui, mat, a0, a1, p, s, c)
      else
        okb = pcall(S.Gui.bitmap, e.gui, mat, p, s, c)
      end
      if okb then once("icon-drew", "icon drawn") end
      return okb
    end

    local function sprite(x, y, rows, cell, colors, layer)
      if type(rows) ~= "table" or type(colors) ~= "table" or not finite(x) or not finite(y) then return end
      cell = tonumber(cell) or 1
      local h = #rows
      for row = 1, h do
        local line = rows[row]
        if type(line) == "string" then
          for col = 1, #line do
            local ch = string.sub(line, col, col)
            local c = colors[ch]
            if c then
              rect(x + (col - 1) * cell, y + (h - row) * cell, cell, cell, c, (layer or 900) + (ch == "o" and 0 or 1))
            end
          end
        end
      end
    end

    -- Chef does not trust units_by_resource until a walk of the world agrees
    -- with it. That call answered 0 here, so the watch walks the world the
    -- way Chef's own scan does: Unit.debug_name, the #ID[hex] in it, 1500
    -- units a frame, on the main world once that world has settled.
    local function name_kind(unit, S)
      local fn = S.Unit and S.Unit.debug_name
      if type(fn) ~= "function" then return false end
      local ok, name = pcall(fn, unit)
      if not ok or type(name) ~= "string" then return false end
      R.saw_names = (R.saw_names or 0) + 1
      local hit = R.names[name]
      if hit ~= nil then return hit end
      local hex = string.match(name, "#ID%[(%x+)%]")
      hex = hex and string.lower(hex) or false
      if (R.names_n or 0) >= 8192 then R.names, R.names_n = {}, 0 end
      R.names[name] = hex
      R.names_n = (R.names_n or 0) + 1
      return hex
    end

    local function service_watches()
      local now = os.clock()
      for i = 1, #R.watches do
        local w = R.watches[i]
        if w.stopped or w.paused then
          w.job = nil
        else
          local job = w.job
          if job and job.world ~= R.held then w.job = nil; job = nil end
          if job then
            local S = stingray()
            if type(S) == "table" and type(S.Unit) == "table" then
              local n = list_n(job.units)
              local last = math.min(n, job.i + 1500)
              for u = job.i + 1, last do
                local unit = job.units[u]
                local hex = name_kind(unit, S)
                if hex and job.set[hex] and alive(unit) then
                  local x, y, z = pos_of(unit)
                  if x then
                    job.out[#job.out + 1] = { unit = unit, kind = hex, x = x, y = y, z = z }
                  end
                end
              end
              job.i = last
              if last >= n then
                w.job = nil
                w.next = now + w.every
                local note = nil
                if w.last_n ~= #job.out then
                  w.last_n = #job.out
                  note = job.where
                  if (R.saw_names or 0) == job.names_at and n > 100 then
                    note = note .. ", no unit names"
                  end
                end
                w.pub.items = job.out
                w.pub.generation = w.pub.generation + 1
                if note then
                  say(w.owner .. " watch: " .. #job.out .. " units (" .. note .. ")")
                  flush()
                end
              end
            end
          elseif now >= w.next and R.stable and R.held ~= nil then
            local S = stingray()
            local units = nil
            if type(S) == "table" and type(S.World) == "table" and type(S.World.units) == "function" then
              local ok, list = pcall(S.World.units, R.held)
              if ok and type(list) == "table" then units = list
              else once("units-list", "World.units: " .. tostring(list)) end
            else
              once("units-list", "World.units is missing")
            end
            if units then
              local set = {}
              for k in pairs(w.kinds) do
                if type(k) == "string" then
                  local hex = string.lower(k)
                  if #hex == 16 and string.match(hex, "^%x+$") and hex ~= BAD_KIND then set[hex] = true end
                end
              end
              local count = measure_world(R.held)
                w.job = {
                units = units, i = 0, set = set, out = {}, world = R.held,
                names_at = R.saw_names or 0, where = count .. " in the world",
              }
            else
              w.next = now + 1
            end
          end
        end
      end
    end

    local function lookup_key(name)
      if type(name) ~= "string" or name == "" then return nil end
      local hit = R.known[name]
      if hit ~= nil then return hit or nil end
      local S = stingray()
      local K = S and S.Keyboard
      if type(K) ~= "table" or type(K.button_index) ~= "function" then return nil end
      local tries = { name }
      local titled = string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
      if titled ~= name then tries[#tries + 1] = titled end
      for i = 1, #tries do
        local ok, found = pcall(K.button_index, tries[i])
        if ok and found ~= nil and found ~= false then
          R.known[name] = found
          return found
        end
      end
      return nil
    end

    local function key_is_down(name)
      local i = lookup_key(name)
      if i == nil then return false end
      return read_button(i)
    end

    local function engine_fn(name)
      local S = stingray()
      if type(S) ~= "table" or type(name) ~= "string" then return nil end
      local obj, meth = string.match(name, "^([%w_]+)%.([%w_]+)$")
      if obj then
        local t = S[obj]
        if type(t) ~= "table" then return nil end
        local fn = t[meth]
        if type(fn) ~= "function" then return nil end
        return fn
      end
      -- Vector3(x, y, z) and Quaternion(x, y, z, w). A dotted name is a
      -- method; these constructors are the table itself.
      if not string.match(name, "^[%w_]+$") then return nil end
      local fn = S[name]
      if type(fn) == "function" or type(fn) == "table" then return fn end
      return nil
    end

    local function call_engine(name, ...)
      local fn = engine_fn(name)
      if not fn then
        if type(name) == "string" then once("call:" .. name, "engine call missing: " .. name) end
        return nil, "missing"
      end
      local packed = { pcall(fn, ...) }
      if not packed[1] then return nil, packed[2] end
      return unpack(packed, 2, #packed)
    end

    local function watch(owner, kinds, every)
      if type(kinds) ~= "table" then return nil end
      local pub = { items = {}, generation = 0, active = true }
      local w = {
        owner = owner, kinds = kinds, every = math.max(0.5, tonumber(every) or 5),
        next = os.clock(), paused = false, stopped = false, pub = pub,
      }
      R.watches[#R.watches + 1] = w
      w.next = 0
      say(owner .. " watch: scanning the world")
      flush()
      function pub.pause()
        w.paused = true
        pub.active = false
      end
      function pub.resume()
        if w.paused and not w.stopped then
          w.paused = false
          pub.active = true
          w.next = 0
        end
      end
      function pub.refresh() w.next = 0 end
      function pub.stop()
        w.stopped, w.paused = true, true
        pub.active = false
        pub.items = {}
      end
      return pub
    end

    local function clamp255(n)
      n = math.floor(tonumber(n) or 0)
      if n < 0 then return 0 end
      if n > 255 then return 255 end
      return n
    end

    -- The game's user_settings.config. Same shape Chef's chef.setting reads:
    -- bare keys, =, { } objects, [ ] arrays, no commas.
    local function parse_sjson(text)
      local i, n = 1, #text
      local function peek() return string.sub(text, i, i) end
      local function skip()
        while true do
          local c = peek()
          if c == "" then return end
          if c == " " or c == "\t" or c == "\r" or c == "\n" then i = i + 1
          elseif c == "/" and string.sub(text, i, i + 1) == "//" then
            local nl = string.find(text, "\n", i, true)
            i = (nl or n) + 1
          else return end
        end
      end
      local function parse_value()
        skip()
        local c = peek()
        if c == "{" then
          i = i + 1
          local t = {}
          while true do
            skip()
            local d = peek()
            if d == "}" or d == "" then if d == "}" then i = i + 1 end return t end
            local key = parse_value()
            skip()
            if peek() == "=" then i = i + 1 end
            local val = parse_value()
            if type(key) == "string" then t[key] = val end
          end
        end
        if c == "[" then
          i = i + 1
          local t = {}
          while true do
            skip()
            local d = peek()
            if d == "]" or d == "" then if d == "]" then i = i + 1 end return t end
            t[#t + 1] = parse_value()
          end
        end
        if c == "\"" then
          i = i + 1
          local out = {}
          while i <= n do
            local ch = peek()
            if ch == "\"" then i = i + 1; break end
            if ch == "\\" then
              out[#out + 1] = string.sub(text, i + 1, i + 1)
              i = i + 2
            else
              out[#out + 1] = ch
              i = i + 1
            end
          end
          return table.concat(out)
        end
        local j = i
        while j <= n do
          local ch = string.sub(text, j, j)
          if ch == "" or string.find(" \t\r\n{}[]=", ch, 1, true) then break end
          j = j + 1
        end
        local tok = string.sub(text, i, j - 1)
        i = j
        if tok == "" then i = i + 1; return nil end
        if tok == "true" then return true end
        if tok == "false" then return false end
        if tok == "null" then return nil end
        return tonumber(tok) or tok
      end
      local root = {}
      while true do
        skip()
        if peek() == "" then return root end
        local key = parse_value()
        skip()
        if peek() == "=" then i = i + 1 end
        local val = parse_value()
        if type(key) == "string" then root[key] = val end
      end
    end

    local function copy_setting(v)
      if type(v) ~= "table" then return v end
      local c = {}
      for k, x in pairs(v) do c[k] = copy_setting(x) end
      return c
    end

    local function game_setting(path)
      if type(path) ~= "string" then return nil end
      local now = os.clock()
      if not (R.settings_at and now < R.settings_at) then
        R.settings_at = now + 30
        R.settings = nil
        local base = settings_path()
        local dir = type(base) == "string" and string.match(base, "^(.*)[\\/][^\\/]+$") or nil
        if dir ~= nil then
          local ok, file = pcall(io.open, dir .. "\\user_settings.config", "r")
          if ok and file ~= nil then
            local text = file:read("*a")
            pcall(function() file:close() end)
            if type(text) == "string" then
              local okp, parsed = pcall(parse_sjson, text)
              if okp and type(parsed) == "table" then R.settings = parsed
              else once("settings", "game settings file could not be read") end
            end
          end
        end
      end
      local t = R.settings
      if type(t) ~= "table" then return nil end
      for part in string.gmatch(path, "[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[tonumber(part) or part]
      end
      return copy_setting(t)
    end

    local function attach(chef, owner)
      local dir = nil
      local settings = settings_path()
      if type(settings) == "string" then dir = string.match(settings, "^(.*)[\\/][^\\/]+$") end
      chef.log_directory = dir or false
      chef.previous_directory = dir or false
      chef.log_file = false
      -- Chef's TOP_FROM. Layers at this value and up are drawn on the HUD
      -- world. Below native, Treasure keeps its own layers and stays here.
      chef.TOP = 2000
      local file = nil
      function chef.log(msg, ...)
        if type(msg) == "string" and select("#", ...) > 0 then
          local ok, formatted = pcall(string.format, msg, ...)
          if ok then msg = formatted end
        end
        say(owner .. ": " .. tostring(msg))
        if file then
          local line = os.date("%H:%M:%S ") .. tostring(msg) .. "\n"
          pcall(function() file:write(line) file:flush() end)
        end
      end
      function chef.own_log(name)
        if file then return true end
        if type(name) ~= "string" or not string.match(name, "^[%w_%-]+$") or #name > 48 or dir == nil then
          return false, "no log"
        end
        local ok, f = pcall(io.open, dir .. "\\" .. name .. ".log", "a")
        if not ok or f == nil then return false, "cannot open" end
        file = f
        chef.log_file = dir .. "\\" .. name .. ".log"
        pcall(function()
          f:write("==== " .. owner .. " " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
          f:flush()
        end)
        say(owner .. " logs to " .. name .. ".log")
        return true
      end
      function chef.key_down(name)
        local down = key_is_down(string.lower(tostring(name or "")))
        if open or capture then return false end
        return down
      end
      function chef.key_pressed(name)
        name = string.lower(tostring(name or ""))
        local down = key_is_down(name)
        local was = R.edge[name]
        R.edge[name] = down and true or nil
        if open or capture then return false end
        return down and not was
      end
      function chef.key_known(name) return lookup_key(string.lower(tostring(name or ""))) ~= nil end
      function chef.time() return os.clock() - R.t0 end
      function chef.setting(path) return game_setting(path) end
      function chef.world_id()
        if not R.stable then return 0 end
        return R.draw_n or 0
      end
      function chef.in_mission() return in_mission() end
      function chef.mission_kinds(kinds)
        if type(kinds) ~= "table" then return end
        for k in pairs(kinds) do
          if type(k) == "string" and string.match(k, "^%x+$") then R.mission_kinds[string.lower(k)] = true end
        end
        local n = 0
        for _ in pairs(R.mission_kinds) do n = n + 1 end
        once("kinds-" .. owner, owner .. " named " .. n .. " mission kinds")
      end
      function chef.ui_textures(map)
        if type(map) ~= "table" then return end
        for k, v in pairs(map) do
          if type(k) == "string" and type(v) == "string" then R.ui[k] = v end
        end
      end
      function chef.texture_sizes(map)
        if type(map) ~= "table" then return end
        for k, list in pairs(map) do
          if type(k) == "string" and type(list) == "table" then R.sizes[k] = list end
        end
      end
      function chef.camera() return camera() end
      function chef.screen() return screen_wh() end
      function chef.world_to_screen(x, y, z)
        if not finite(x) or not finite(y) or not finite(z) then return nil end
        local d = camera()
        if not d or d.cam == nil then return nil end
        local ax, ay, az = x - d.x, y - d.y, z - d.z
        if ax * d.fx + ay * d.fy + az * d.fz <= 0.5 then return nil end
        local S = stingray()
        if type(S.Camera) ~= "table" or type(S.Camera.world_to_screen) ~= "function" then return nil end
        local v = vec3(x, y, z)
        if not v then return nil end
        local ok, r = pcall(S.Camera.world_to_screen, d.cam, v)
        if not ok then return nil end
        local sx, sy = xyz(r)
        if not sx then return nil end
        return sx, sy
      end
      function chef.color(r, g, b, a)
        local S = stingray()
        if not S then return nil end
        return color(S, clamp255(a or 255), clamp255(r), clamp255(g), clamp255(b))
      end
      function chef.text_width(str, px) return text_width(str, px) end
      function chef.rect(x, y, w, h, c, layer) rect(x, y, w, h, c, layer) end
      function chef.text(x, y, s, px, c, layer) return text(x, y, s, px, c, layer) end
      function chef.bitmap(tex, x, y, w, h, c, layer) return bitmap(tex, x, y, w, h, c, layer) end
      function chef.sprite(x, y, rows, cell, colors, layer) sprite(x, y, rows, cell, colors, layer) end
      function chef.watch(kinds, every) return watch(owner, kinds, every) end
      function chef.call(name, ...) return call_engine(name, ...) end
      function chef.call_kind(name, kind, ...)
        if type(kind) == "string" and string.lower(kind) == BAD_KIND then return nil, "runtime-built unit" end
        return call_engine(name, ...)
      end

      local budget_ms = 4
      function chef.budget(ms)
        if type(ms) == "number" and ms > 0 then budget_ms = ms end
        return budget_ms
      end
      function chef.world() return draw_world() end

      local function askable(u)
        local k = chef.unit_kind(u)
        if not k or k == BAD_KIND then return nil end
        if not alive(u) then return nil end
        return k
      end
      function chef.unit_kind(u)
        if u == nil then return nil end
        local hit = R.kinds[u]
        if hit ~= nil then return hit or nil end
        local S = stingray()
        if type(S) ~= "table" then return nil end
        local hex = name_kind(u, S)
        if type(hex) ~= "string" then return nil end
        R.kinds[u] = hex
        return hex
      end
      function chef.unit_alive(u)
        if u == nil then return false end
        return alive(u)
      end
      function chef.unit_position(u, node)
        if not askable(u) then return nil end
        local p = call_engine("Unit.world_position", u, tonumber(node) or 1)
        return xyz(p)
      end
      function chef.unit_rotation(u, node)
        if not askable(u) then return nil end
        local q = call_engine("Unit.world_rotation", u, tonumber(node) or 1)
        if q == nil then return nil end
        local fx, fy, fz = xyz(call_engine("Quaternion.forward", q))
        if not fx then return nil end
        return fx, fy, fz, math.atan2(fx, fy)
      end
      function chef.unit_node(u, name)
        if type(name) ~= "string" or not askable(u) then return nil end
        if call_engine("Unit.has_node", u, name) ~= true then return nil end
        return call_engine("Unit.node", u, name)
      end

      function chef.spawn(res, x, y, z)
        local world = draw_world()
        if world == nil then return nil, "no world yet" end
        x, y, z = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
        if not (finite(x) and finite(y) and finite(z)) then return nil, "x, y, z: finite numbers" end
        if type(res) ~= "string" or not string.match(res, "^%x+$") then return nil, "no id" end
        local id = fresh_id(res)
        if id == nil then return nil, "no id" end
        if call_engine("Application.can_get", "unit", id) ~= true then
          return nil, "unit " .. res .. " is not loaded"
        end
        local p = vec3(x, y, z)
        if not p then return nil, "no position" end
        local u, err = call_engine("World.spawn_unit", world, id, p)
        if u == nil then return nil, err end
        R.made[#R.made + 1] = { owner = owner, h = u, world = world }
        return u
      end
      function chef.despawn(u)
        local made = R.made
        if type(made) ~= "table" then return false end
        for i = 1, #made do
          local m = made[i]
          if m and m.h == u and m.owner == owner then
            table.remove(made, i)
            if m.world == draw_world() and alive(u) then
              call_engine("World.destroy_unit", m.world, u)
            end
            return true
          end
        end
        return false
      end

      function chef.line(x1, y1, z1, x2, y2, z2, c)
        local world = draw_world()
        if world == nil or c == nil then return end
        if not (finite(x1) and finite(y1) and finite(z1) and finite(x2) and finite(y2) and finite(z2)) then return end
        if R.lines_world ~= world then
          R.lines, R.lines_world, R.lines_used, R.lines_shown = nil, world, false, false
        end
        if R.lines == nil then
          R.lines = call_engine("World.create_line_object", world) or false
        end
        if not R.lines then return end
        if not R.lines_used then
          call_engine("LineObject.reset", R.lines)
          R.lines_used = true
        end
        local a, b = vec3(x1, y1, z1), vec3(x2, y2, z2)
        if a and b then call_engine("LineObject.add_line", R.lines, c, a, b) end
      end

      function chef.spread(list, per_frame, fn, done, opts)
        if type(list) ~= "table" or type(fn) ~= "function" then return nil end
        local j = {
          list = list, per = math.max(1, math.floor(tonumber(per_frame) or 50)),
          fn = fn, done = type(done) == "function" and done or nil,
          i = 0, on = true, errors = 0,
          keep = type(opts) == "table" and opts.keep == true,
        }
        R.jobs[#R.jobs + 1] = j
        return {
          cancel = function() j.on = false end,
          active = function() return j.on end,
          progress = function() return j.i, list_n(j.list) end,
        }
      end

      local function session_now()
        local now = os.clock()
        local s = R.session
        if type(s) == "table" and s.at and now < s.at + 1 then return s end
        s = { at = now, on = false, host = nil, me = nil, peers = 0, joining = 0 }
        local sess = call_engine("Network.game_session")
        s.me = call_engine("Network.peer_id")
        if sess ~= nil and call_engine("GameSession.in_session", sess) == true then
          s.on = true
          s.host = call_engine("GameSession.game_session_host", sess)
          local peers = call_engine("GameSession.peers", sess)
          if type(peers) == "table" then
            local n = 0
            for _ in pairs(peers) do n = n + 1 end
            s.peers = n
          end
          local joining = call_engine("GameSession.synchronizing_peers", sess)
          if type(joining) == "table" then
            local n = 0
            for _ in pairs(joining) do n = n + 1 end
            s.joining = n
          end
        end
        R.session = s
        return s
      end
      function chef.is_host()
        local s = session_now()
        if not s.on then return true end
        return s.host ~= nil and s.host == s.me
      end
      function chef.players()
        local s = session_now()
        if not s.on then return 1 end
        if s.peers < 1 then return 1 end
        return s.peers
      end

      function chef.wheel()
        if open or capture then return 0 end
        local ix = call_engine("Mouse.axis_index", "wheel")
        if ix == nil then return 0 end
        local _, y = xyz(call_engine("Mouse.axis", ix))
        if type(y) ~= "number" then return 0 end
        return y
      end
      function chef.mouse_down(name)
        if open or capture or type(name) ~= "string" then return false end
        local ix = call_engine("Mouse.button_index", name)
        if ix == nil then return false end
        local v = call_engine("Mouse.button", ix)
        return type(v) == "number" and v > 0.5
      end

      function chef.notify(msg, seconds, r, g, b)
        if type(msg) ~= "string" or msg == "" then return false end
        local n = 0
        for i = 1, #R.notes do
          if R.notes[i].owner == owner then n = n + 1 end
        end
        if n >= 3 then return false end
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if not (finite(r) and finite(g) and finite(b)) then r, g, b = 235, 235, 235 end
        r = math.max(0, math.min(255, r))
        g = math.max(0, math.min(255, g))
        b = math.max(0, math.min(255, b))
        local shown = string.upper(string.sub(msg, 1, 80))
        local dur = tonumber(seconds) or 4
        if dur < 1 then dur = 1 elseif dur > 30 then dur = 30 end
        R.notes[#R.notes + 1] = { owner = owner, text = shown, r = r, g = g, b = b, until_t = os.clock() + dur }
        return true
      end

      local function data_file(name)
        if type(name) ~= "string" or not string.match(name, "^[%w_%-]+$") or #name > 48 or dir == nil then
          return nil
        end
        local who = string.gsub(owner, "[^%w_%-]", "_")
        return dir .. "\\ordnance-" .. who .. "-" .. name .. ".lua"
      end
      local function dump_value(v, seen)
        local t = type(v)
        if t == "number" then
          if v ~= v or v == math.huge or v == -math.huge then return nil end
          return string.format("%.17g", v)
        elseif t == "string" then
          return string.format("%q", v)
        elseif t == "boolean" then
          return v and "true" or "false"
        elseif t == "table" then
          if seen[v] then return nil end
          seen[v] = true
          local parts, n = {}, 0
          for k, x in pairs(v) do
            local ks
            if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then ks = k
            elseif type(k) == "string" then ks = "[" .. string.format("%q", k) .. "]"
            elseif type(k) == "number" and k == k then ks = "[" .. string.format("%.17g", k) .. "]"
            end
            local vs = ks and dump_value(x, seen)
            if ks and vs then
              n = n + 1
              parts[n] = ks .. "=" .. vs
            end
          end
          seen[v] = nil
          return "{" .. table.concat(parts, ",") .. "}"
        end
        return nil
      end
      function chef.save_table(name, t)
        local path = data_file(name)
        if not path then return false, "names are letters, digits, _ - (48 at most)" end
        if type(t) ~= "table" then return false, "only a table" end
        local text = dump_value(t, {})
        if not text or #text > 1000000 then return false, "could not save" end
        local ok, f = pcall(io.open, path, "w")
        if not ok or f == nil then return false, "cannot open" end
        local wrote = pcall(function() f:write("return ", text, "\n") f:close() end)
        if not wrote then return false, "cannot write" end
        return true
      end
      function chef.load_table(name)
        local path = data_file(name)
        if not path then return nil, "bad name" end
        local ok, f = pcall(io.open, path, "r")
        if not ok or f == nil then return nil, "none saved" end
        local text = f:read("*a")
        pcall(function() f:close() end)
        if type(text) ~= "string" or text == "" then return nil, "none saved" end
        local chunk, err = loadstring(text, "@" .. name)
        if chunk == nil then return nil, err end
        if type(setfenv) == "function" then setfenv(chunk, {}) end
        local ran, result = pcall(chunk)
        if not ran or type(result) ~= "table" then return nil, "bad file" end
        return result
      end

      local function version_ok(have, want)
        if want == nil or want == "" then return true end
        if type(have) ~= "string" then return false end
        local function parts(s)
          local t = {}
          for n in string.gmatch(s, "%d+") do t[#t + 1] = tonumber(n) end
          return t
        end
        local a, b = parts(have), parts(want)
        local n = #a
        if #b > n then n = #b end
        for i = 1, n do
          local x, y = a[i] or 0, b[i] or 0
          if x ~= y then return x > y end
        end
        return true
      end
      function chef.require(name, want)
        if type(name) ~= "string" then return nil, "a mod name is a string" end
        local other = R.exports[name]
        if other and other.on and type(other.module) == "table" then
          if not version_ok(other.version, want) then
            return nil, name .. " is " .. tostring(other.version) .. ", " .. tostring(want) .. " or newer is needed"
          end
          return other.module
        end
        if type(package) == "table" and type(package.loaded) == "table" and package.loaded[name] == true then
          return nil, name .. " is a boot-style mod: it has no exports"
        end
        return nil, name .. " is not running"
      end
      function chef.share(name, value)
        if type(name) ~= "string" then return false end
        local prev = R.shared[name]
        if prev and prev.owner ~= owner then
          say(owner .. " share: replaced " .. tostring(prev.owner) .. "'s " .. name)
        end
        R.shared[name] = { owner = owner, value = value }
        return true
      end
      function chef.shared(name)
        local s = R.shared[name]
        if s then return s.value end
      end
      function chef.on(event, fn)
        if type(event) ~= "string" or type(fn) ~= "function" then return nil end
        if event == "players" then R.watch_players = true end
        local list = R.subs[event]
        if list == nil then list = {} R.subs[event] = list end
        local sb = { fn = fn, on = true, errors = 0 }
        list[#list + 1] = sb
        return function() sb.on = false end
      end
      function chef.emit(event, ...)
        if type(event) == "string" then return R.emit(event, ...) end
      end
      local function timer(delay, every, fn)
        if type(fn) ~= "function" or type(delay) ~= "number" then return nil end
        if #R.timers >= 512 then return nil end
        if delay < 0 then delay = 0 end
        local t = { at = os.clock() + delay, every = every and delay or nil, fn = fn, on = true, errors = 0 }
        R.timers[#R.timers + 1] = t
        return { cancel = function() t.on = false end, active = function() return t.on end }
      end
      function chef.after(s, fn) return timer(s, false, fn) end
      function chef.every(s, fn) return timer(s, true, fn) end
      function chef.in_session() return session_now().on == true end
      function chef.joining()
        local s = session_now()
        if not s.on then return 0 end
        return s.joining or 0
      end
      function chef.peer_id() return session_now().me end
      function chef.mods()
        local out = {}
        for i = 1, #R.roster do
          local m = R.roster[i]
          out[i] = { name = m.name, kind = "addon", on = m.on == true, version = m.version, errors = 0 }
        end
        return out
      end
      function chef.link(child, parent, parent_node, child_node)
        local world = draw_world()
        if world == nil or child == nil or parent == nil then return nil, "not in this world" end
        local pn = parent_node or 1
        if type(pn) == "string" then
          pn = chef.unit_node(parent, pn)
          if not pn then return nil, "no node " .. tostring(parent_node) end
        end
        local _, err = call_engine("World.link_unit", world, child, child_node or 1, parent, pn)
        if err ~= nil then return nil, err end
        return true
      end
      function chef.unlink(child)
        local world = draw_world()
        if world == nil or child == nil then return nil, "not in this world" end
        local _, err = call_engine("World.unlink_unit", world, child)
        if err ~= nil then return nil, err end
        return true
      end
      function chef.particles(res, x, y, z)
        local world = draw_world()
        if world == nil then return nil, "no world yet" end
        x, y, z = tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
        if not (finite(x) and finite(y) and finite(z)) then return nil, "x, y, z: finite numbers" end
        if type(res) ~= "string" then return nil, "no id or position" end
        local id = fresh_id(res)
        local p = vec3(x, y, z)
        if not (id and p) then return nil, "no id or position" end
        local h, err = call_engine("World.create_particles", world, id, p)
        if h == nil then return nil, err end
        R.made[#R.made + 1] = { owner = owner, h = h, kind = "particles", world = world }
        return h
      end
      function chef.stop_particles(h)
        local made = R.made
        for i = 1, #made do
          local m = made[i]
          if m and m.h == h and m.kind == "particles" and m.owner == owner then
            table.remove(made, i)
            if m.world == draw_world() then call_engine("World.destroy_particles", m.world, h) end
            return true
          end
        end
        return false
      end
      function chef.lights(u)
        if not askable(u) then return 0 end
        local n = call_engine("Unit.num_lights", u)
        if type(n) ~= "number" then return 0 end
        return n
      end
      function chef.light(u, i)
        local L2 = {}
        local function get()
          if not askable(u) then return nil end
          return call_engine("Unit.light", u, i or 1)
        end
        local function set(name, ...)
          local l = get()
          if l == nil then return false end
          local _, err = call_engine(name, l, ...)
          return err == nil
        end
        function L2.set_color(r, g, b)
          local v = vec3((tonumber(r) or 255) / 255, (tonumber(g) or 255) / 255, (tonumber(b) or 255) / 255)
          if not v then return false end
          return set("Light.set_color", v)
        end
        function L2.set_intensity(v) return set("Light.set_intensity", v) end
        function L2.set_enabled(on) return set("Light.set_enabled", on == true) end
        function L2.set_falloff(s, e)
          return set("Light.set_falloff_start", s) and set("Light.set_falloff_end", e)
        end
        function L2.set_shadows(on) return set("Light.set_casts_shadows", on == true) end
        return L2
      end
      function chef.units_near(x, y, z, r, w)
        local out = {}
        if not (finite(x) and finite(y) and finite(z) and finite(r)) or r < 0 then return out end
        local r2 = r * r
        local lists = {}
        if w and type(w.items) == "table" then lists[1] = w
        else
          for i = 1, #R.watches do
            if R.watches[i].owner == owner then lists[#lists + 1] = R.watches[i].pub end
          end
        end
        for i = 1, #lists do
          local items = lists[i] and lists[i].items
          if type(items) == "table" then
            for k = 1, #items do
              local it = items[k]
              local dx, dy, dz = (it.x or 0) - x, (it.y or 0) - y, (it.z or 0) - z
              local d2 = dx * dx + dy * dy + dz * dz
              if d2 <= r2 then
                out[#out + 1] = { unit = it.unit, kind = it.kind, x = it.x, y = it.y, z = it.z, d = math.sqrt(d2) }
              end
            end
          end
        end
        table.sort(out, function(a, b) return a.d < b.d end)
        return out
      end
      function chef.ray_box(from, dir, box, extents)
        local S = stingray()
        local fn = S and S.Math and S.Math.ray_box_intersection
        if type(fn) ~= "function" then return nil, "no ray test" end
        local ok, dist = pcall(fn, from, dir, box, extents)
        if not ok then return nil, dist end
        if type(dist) ~= "number" then return nil end
        return dist
      end
      function chef.capture(what)
        if what ~= nil and what ~= "depth" then return nil, "it takes only the word 'depth', or nothing" end
        return nil, "not available to this mod"
      end
      function chef.cursor()
        local ix = call_engine("Mouse.axis_index", "cursor")
        if ix == nil then return nil end
        local x, y = xyz(call_engine("Mouse.axis", ix))
        if type(x) ~= "number" or type(y) ~= "number" then return nil end
        return x, y
      end
      function chef.mouse_delta()
        local x, y = chef.cursor()
        local dx, dy = 0, 0
        if x and R.cur_x then dx, dy = x - R.cur_x, y - R.cur_y end
        if x then R.cur_x, R.cur_y = x, y end
        return dx, dy
      end
      function chef.mouse_held() return next(R.holds) ~= nil end
      function chef.hold_mouse(flag)
        local ix = call_engine("Mouse.axis_index", "mouse")
        if flag ~= false then
          if ix == nil then return false, "the mouse can't be held: the game gave no mouse axis" end
          local mode, size = call_engine("Mouse.dead_zone", ix)
          if type(mode) ~= "number" or type(size) ~= "number" then
            return false, "the mouse can't be held: the game gave no dead zone for it"
          end
          if not R.hold_saved and size < 100000 then
            local ok = pcall(function()
              stingray().Mouse.set_dead_zone(ix, 1, 917351)
            end)
            if not ok then return false, "the mouse can't be held: the game gave no dead zone for it" end
            R.hold_saved = { ix = ix, mode = mode, size = size }
          end
          R.holds[owner] = true
          return true
        end
        R.holds[owner] = nil
        if next(R.holds) == nil and R.hold_saved then
          local saved = R.hold_saved
          R.hold_saved = nil
          pcall(function() stingray().Mouse.set_dead_zone(saved.ix, saved.mode, saved.size) end)
        end
        return true
      end
      function chef.typed()
        if open or capture then return "", {} end
        local S = stingray()
        local ks = S and S.Keyboard and S.Keyboard.keystrokes
        if type(ks) ~= "function" then return "", {} end
        local ok, text, keys = pcall(ks)
        if not ok then return "", {} end
        if type(text) == "string" then return text, type(keys) == "table" and keys or {} end
        if type(text) == "table" then return "", text end
        return "", {}
      end
      function chef.key_label(name)
        if type(name) ~= "string" then return "" end
        if #name > 64 then return name end
        local pad = string.match(name, "^pad:(.+)$")
        if pad then return "Pad " .. string.gsub(pad, "_", " ") end
        return name
      end
      function chef.lang() return nil end
      function chef.tr(s) return s end
      function chef.text_fit(s, px, maxw)
        s = tostring(s or "")
        if not (finite(px) and finite(maxw)) or text_width(s, px) <= maxw then return s end
        local ell, n = "...", #s
        while n > 0 and text_width(string.sub(s, 1, n) .. ell, px) > maxw do n = n - 1 end
        if n <= 0 then
          if text_width(ell, px) <= maxw then return ell end
          return ""
        end
        return string.sub(s, 1, n) .. ell
      end
      function chef.text_wrap(s, px, maxw, most)
        s = tostring(s or "")
        most = tonumber(most)
        if not most or most < 1 then most = 64 elseif most > 1024 then most = 1024 end
        if not (finite(px) and finite(maxw)) or maxw <= 0 then return { s } end
        local lines, cur = {}, ""
        for word in string.gmatch(s, "%S+") do
          local trial = cur == "" and word or (cur .. " " .. word)
          if text_width(trial, px) <= maxw then cur = trial
          else
            if cur ~= "" then lines[#lines + 1] = cur end
            cur = word
            if #lines >= most then break end
          end
        end
        if cur ~= "" and #lines < most then lines[#lines + 1] = cur end
        if #lines == 0 then lines[1] = "" end
        return lines
      end
      function chef.bitmap_uv(tex, u0, v0, u1, v1, x, y, w, h, c, layer)
        return bitmap(tex, x, y, w, h, c, layer, u0, v0, u1, v1)
      end
      function chef.sprite_sheet(tex, cols, rows)
        cols = math.max(1, math.floor(tonumber(cols) or 1))
        rows = math.max(1, math.floor(tonumber(rows) or 1))
        local sheet = { tex = tex, cols = cols, rows = rows }
        function sheet.draw(i, x, y, w, h, c, layer)
          i = math.floor(tonumber(i) or 1) - 1
          if i < 0 or i >= cols * rows then return false end
          local cx, cy = i % cols, math.floor(i / cols)
          return bitmap(tex, x, y, w, h, c, layer, cx / cols, cy / rows, (cx + 1) / cols, (cy + 1) / rows)
        end
        return sheet
      end
      local function arc_draw(x, y, r_in, r_out, a0, a1, c, layer)
        if not (finite(x) and finite(y) and finite(r_out) and c) then return end
        r_in = tonumber(r_in) or 0
        a0, a1 = tonumber(a0) or 0, tonumber(a1) or 360
        if a1 < a0 then a0, a1 = a1, a0 end
        local span = a1 - a0
        if span > 360 then span = 360 end
        if span <= 0 then return end
        local steps = math.max(8, math.floor(span / 12))
        local mid = (r_in + r_out) / 2
        local thick = r_out - r_in
        if thick < 1 then thick = 1 end
        for i = 0, steps - 1 do
          local deg = (a0 + span * (i + 0.5) / steps) * math.pi / 180
          rect(x + math.sin(deg) * mid, y + math.cos(deg) * mid, thick, thick, c, layer)
        end
      end
      function chef.arc(x, y, r_in, r_out, a0, a1, c, layer) arc_draw(x, y, r_in, r_out, a0, a1, c, layer) end
      function chef.circle(x, y, r, c, layer) arc_draw(x, y, 0, r, 0, 360, c, layer) end
      function chef.ring(x, y, r_in, r_out, c, layer) arc_draw(x, y, r_in, r_out, 0, 360, c, layer) end
      function chef.triangle(x1, y1, x2, y2, x3, y3, c, layer)
        if c == nil then return end
        local function edge(ax, ay, bx, by)
          if not (finite(ax) and finite(ay) and finite(bx) and finite(by)) then return end
          local dx, dy = bx - ax, by - ay
          local len = math.sqrt(dx * dx + dy * dy)
          local n = math.max(1, math.floor(len / 4))
          for i = 0, n do
            local t = i / n
            rect(ax + dx * t, ay + dy * t, 2, 2, c, layer)
          end
        end
        edge(x1, y1, x2, y2)
        edge(x2, y2, x3, y3)
        edge(x3, y3, x1, y1)
      end
      function chef.index()
        R.index_wanted = true
        local ix = R.index
        if not ix or not ix.ready then return nil, "building" end
        return ix.view
      end
      R.refresh_session = session_now
    end

    local function adopt(name, result)
      if type(result) ~= "table" then return end
      R.exports[name] = {
        name = name, on = true, module = result,
        version = type(result.version) == "string" and result.version or nil,
      }
      R.roster[#R.roster + 1] = R.exports[name]
      local hooks = {}
      for _, key in ipairs({ "update", "render", "shutdown" }) do
        local fn = rawget(result, key)
        -- A function already installed as the global callback runs from that
        -- chain. Calling it again here would run the mod twice a frame.
        if type(fn) == "function" and rawget(_G, key) ~= fn then hooks[key] = fn end
      end
      local stop = rawget(result, "on_stop")
      if next(hooks) == nil and type(stop) ~= "function" then return end
      R.modules[#R.modules + 1] = {
        name = name, hooks = hooks, stop = type(stop) == "function" and stop or nil, n = 0,
      }
      local names = {}
      for k in pairs(hooks) do names[#names + 1] = k end
      table.sort(names)
      say(name .. ": module runs " .. (#names > 0 and table.concat(names, ", ") or "on_stop"))
      flush()
    end

    R.service_jobs = function()
      local jobs = R.jobs
      if type(jobs) ~= "table" then return end
      local i = 1
      while i <= #jobs do
        local j = jobs[i]
        if type(j) ~= "table" or not j.on then
          table.remove(jobs, i)
        else
          local n = list_n(j.list)
          local last = math.min(n, j.i + j.per)
          while j.i < last do
            j.i = j.i + 1
            local ok = pcall(j.fn, j.list[j.i], j.i)
            if not ok then j.errors = (j.errors or 0) + 1 end
          end
          if j.i >= n or (j.errors or 0) >= 8 then
            j.on = false
            if type(j.done) == "function" then pcall(j.done, (j.errors or 0) < 8 and j.i >= n) end
            table.remove(jobs, i)
          else
            i = i + 1
          end
        end
      end
    end

    R.dispatch_lines = function()
      local world = draw_world()
      if R.lines and R.lines_used and world ~= nil and R.lines_world == world then
        call_engine("LineObject.dispatch", world, R.lines)
        R.lines_shown = true
        R.lines_used = false
        R.lines_drew = R.frame
      elseif R.lines_shown and R.lines and world ~= nil and R.lines_world == world and R.lines_drew ~= R.frame then
        call_engine("LineObject.reset", R.lines)
        call_engine("LineObject.dispatch", world, R.lines)
        R.lines_shown = false
      end
    end

    R.draw_notes = function()
      local notes = R.notes
      if type(notes) ~= "table" or #notes == 0 then return end
      local now = os.clock()
      local _, h = screen_wh()
      local y = (h or 1080) - 48
      local i = 1
      while i <= #notes do
        local n = notes[i]
        if now >= n.until_t then
          table.remove(notes, i)
        else
          local c = color(stingray(), 255, n.r, n.g, n.b)
          if c then text(40, y, n.text, 18, c, 1900) end
          y = y - 22
          i = i + 1
        end
      end
    end

    local function drive(kind, dt)
      if R.stopped then return end
      if kind == "shutdown" then
        R.emit("shutdown")
        if hd2rt_dispatch then pcall(hd2rt_dispatch, "shutdown") end
        R.stopped = true
        for i = 1, #R.modules do
          local m = R.modules[i]
          if m.stop then
            local ok, err = pcall(m.stop)
            if not ok then say(m.name .. " on_stop: " .. tostring(err)) end
          end
          if m.hooks.shutdown then
            local ok, err = pcall(m.hooks.shutdown)
            if not ok then say(m.name .. " shutdown: " .. tostring(err)) end
          end
        end
        drop_draw()
        flush()
        return
      end
      if kind == "update" then
        R.frame = R.frame + 1
        wipe_text(R.text)
        wipe_text(R.top_text)
        settle(main_world(), os.clock())
        R.settle_frame = R.frame
        service_watches()
      end
      for i = 1, #R.modules do
        local m = R.modules[i]
        local fn = m.hooks[kind]
        if fn then
          local ok, err = pcall(fn, dt)
          if not ok then
            m.n = m.n + 1
            if m.n <= 3 or m.n % 300 == 0 then
              say(m.name .. " " .. kind .. ": " .. tostring(err))
              flush()
            end
          end
        end
      end
      if kind == "update" then
        R.service_jobs()
        R.service_timers()
        R.service_index()
        if R.watch_players and R.refresh_session then R.refresh_session() end
        local mission = in_mission()
        if R.was_mission and not mission then R.emit("mission_end") end
        R.was_mission = mission
        if R.session then
          local sig = tostring(R.session.peers or 0) .. ":" .. tostring(R.session.joining or 0)
          if sig ~= R.peer_sent then
            R.peer_sent = sig
            R.emit("players", R.session.peers or 0, R.session.joining or 0)
          end
        end
        if hd2rt_dispatch then pcall(hd2rt_dispatch, "update", dt) end
      end
      if kind == "render" then
        R.draw_notes()
        if hd2rt_dispatch then pcall(hd2rt_dispatch, "render", dt) end
      end
      if kind == "update" or kind == "render" then R.dispatch_lines() end
    end

    R.emit = function(event, ...)
      local list = R.subs[event]
      if type(list) ~= "table" then return end
      for i = 1, #list do
        local sb = list[i]
        if sb.on then
          local ok = pcall(sb.fn, ...)
          if not ok then
            sb.errors = sb.errors + 1
            if sb.errors >= 8 then sb.on = false end
          end
        end
      end
    end

    R.service_timers = function()
      local now = os.clock()
      local list = R.timers
      local n = #list
      local i = 1
      while i <= n do
        local t = list[i]
        if type(t) ~= "table" or not t.on then
          table.remove(list, i)
          n = n - 1
        elseif now >= t.at then
          local ok = pcall(t.fn)
          if not ok then t.errors = (t.errors or 0) + 1 end
          if t.every and t.on and (t.errors or 0) < 8 then
            t.at = now + t.every
            i = i + 1
          else
            t.on = false
            table.remove(list, i)
            n = n - 1
          end
        else
          i = i + 1
        end
      end
    end

    R.service_index = function()
      if not R.index_wanted then return end
      local ix = R.index
      if ix == nil then
        local dir, sep = data_dir()
        if not dir then return end
        R.index = { dir = dir, sep = sep, n = 0, last = -1, by = {}, patches = {}, ready = false }
        ix = R.index
      end
      local types = {
        e0a48d0be9a7453f = "unit", eac0b497876adedf = "material", cd4238c6a0c69e32 = "texture",
        ad9c6d9ed1e5e77a = "package", a14e8dfa2cd117e2 = "lua", ["18dead01056b72e9"] = "bones",
        ["931e336d7646cc26"] = "animation", a486d4045106165c = "state_machine", a8193123526fad64 = "particles",
        ["535a7bd3e650d799"] = "wwise_bank", ["504b55235d21440e"] = "wwise_stream", af32095c82f2b070 = "wwise_dep",
        ["9efe0a916aae7880"] = "font", e5ee32a477239a93 = "shader_library", ["0d972bab10b40fd3"] = "strings",
        c4f0f4be7fb0c8d6 = "geometry_group", ["5f7203c8f280dab8"] = "physics", ab2f78e885f513c6 = "prefab",
        ["2a690fd348fe9ac5"] = "level", ["9831ca893b0d087d"] = "entity", ["27862fe24795319c"] = "render_config",
        e985c5f61c169997 = "speedtree",
      }
      local function finish()
        if ix.view then return end
        local by, named = ix.by, types
        ix.view = {
          providers = function(ty, id)
            if type(ty) ~= "string" or type(id) ~= "string" then return {} end
            if not string.match(id, "^%x+$") or #id ~= 16 then return {} end
            local key = ty
            if #ty ~= 16 then
              key = nil
              for hex, name in pairs(named) do
                if name == ty then key = hex break end
              end
            end
            if key == nil or not string.match(key, "^%x+$") or #key ~= 16 then return {} end
            local list = by[string.lower(key) .. string.lower(id)] or {}
            local out = {}
            for i = 1, #list do
              local p = list[i]
              out[i] = { patch = p.patch, number = p.number, file = p.file, mods = {} }
            end
            return out
          end,
          winner = function(ty, id)
            local list = ix.view.providers(ty, id)
            return list[1]
          end,
          patches = function() return ix.patches end,
          conflicts = function() return {} end,
        }
      end
      if ix.ready then finish() return end
      if ix.file == nil then
        if ix.n > MAX_PATCH then
          ix.ready = true
          finish()
          return
        end
        local path = ix.dir .. ix.sep .. ARCHIVE .. ".patch_" .. ix.n
        local f = io.open(path, "rb")
        if f == nil then
          if ix.n - ix.last > GAP then ix.ready = true finish() return end
          ix.n = ix.n + 1
          return
        end
        ix.last = ix.n
        local head = f:read(12)
        local ntypes = head and u32(head, 4) or nil
        local count = head and u32(head, 8) or nil
        if head == nil or u32(head, 0) ~= 0xF0000011 or not ntypes or not count or count > 200000 then
          f:close()
          ix.n = ix.n + 1
          return
        end
        local entry = { patch = ix.n, number = ix.n, file = path, mods = {} }
        ix.patches[#ix.patches + 1] = entry
        f:seek("set", 0x48 + ntypes * 32)
        ix.file = f
        ix.left = count
        ix.entry = entry
        return
      end
      local chunk = ix.file:read(math.min(ix.left, 40) * 80)
      if type(chunk) ~= "string" or #chunk < 80 then
        ix.file:close()
        ix.file = nil
        ix.n = ix.n + 1
        return
      end
      local rows = math.floor(#chunk / 80)
      for i = 0, rows - 1 do
        local at = i * 80
        local id = hex64(chunk, at)
        local ty = hex64(chunk, at + 8)
        if id and ty then
          local key = ty .. id
          local list = ix.by[key]
          if list == nil then list = {} ix.by[key] = list end
          list[#list + 1] = ix.entry
        end
      end
      ix.left = ix.left - rows
      if ix.left <= 0 then
        ix.file:close()
        ix.file = nil
        ix.n = ix.n + 1
      end
      if ix.n > MAX_PATCH and ix.file == nil then ix.ready = true end
      if ix.ready then finish() end
    end

    return { drive = drive, adopt = adopt, attach = attach, emit = function(event, ...) return R.emit(event, ...) end }
  end)()

  local option_sets = {}

  local function chef_for(owner)
    local chef = {
      version = "ordnance-loader-1", api = 1, loader = "ordnance", loader_version = "0.4.6",
      options = option_sets[owner] or {},
    }
    local caps = {
      api = true, after_startup = true, settings = true, share = true, events = true, require = true,
      bind = true, menu = true, shims = true, dev = false, logs = true, own_log = true, mouse_hold = true,
      players_event = true, hang_watchdog = false, option_buttons = true, option_colors = true,
      option_headings = true, menu_state = true, mod_stopped_event = true, bind_combos = true, option_folds = true,
      units = true, spawn = true, timers = true, budget = true, session = true, settings_file = true,
      shapes = true, sprite_sheets = true, notify = true, typed = true, key_labels = true, save_table = true,
      mods = true, health = true, index = true, joining = true, bindings = true,
    }
    chef.capabilities = setmetatable({}, {
      __index = caps,
      __newindex = function() error("chef.capabilities is read-only", 2) end,
    })
    function chef.has(name)
      if name == "hang_watchdog" then return false end
      if name == "ray_box" then
        local S = stingray()
        return type(S) == "table" and type(S.Math) == "table" and type(S.Math.ray_box_intersection) == "function"
      end
      return chef.capabilities[name] == true
    end
    function chef.title(t) if type(t) == "string" then group(owner, t) end end
    function chef.menu_open() return open end
    function chef.after_startup(fn)
      if type(fn) == "function" then after_startup[#after_startup + 1] = fn end
    end
    function chef.save(key, value)
      if type(key) == "string" then store(owner, key, value) end
    end
    function chef.load(key, default) return stored(owner, key, default) end
    function chef.option(id, spec)
      local row, err = add_option(owner, id, spec)
      if not row then
        say(owner .. " option " .. tostring(id) .. ": " .. tostring(err))
        return nil, err
      end
      return row.value
    end
    function chef.get(id)
      local row = rows[owner .. "|" .. tostring(id)]
      if row then return row.value end
    end
    function chef.set(id, value)
      local row = rows[owner .. "|" .. tostring(id)]
      if row then return set_value(row, value, true) end
    end
    function chef.on_change(id, fn)
      local row = rows[owner .. "|" .. tostring(id)]
      if row and type(fn) == "function" then
        row.changed[#row.changed + 1] = fn
        return true
      end
      return false
    end
    function chef.button(id, label, fn, text)
      return chef.option(id, { type = "button", label = label, run = fn, text = text })
    end
    function chef.bind(id, default_key, label)
      local row, err = add_option(owner, id, { type = "key", default = default_key or "off", label = label or id })
      if not row then return nil, err end
      local b = {}
      function b.key() return row.value end
      function b.pressed()
        if open or capture then return false end
        return binding_down(row.value, true)
      end
      function b.down()
        if open or capture then return false end
        return binding_down(row.value, false)
      end
      return b
    end
    function chef.rgb(v)
      local h = type(v) == "string" and string.match(v, "^#?(%x%x%x%x%x%x)$")
      if not h then return nil end
      h = string.upper(h)
      return tonumber(string.sub(h, 1, 2), 16), tonumber(string.sub(h, 3, 4), 16), tonumber(string.sub(h, 5, 6), 16)
    end
    runtime.attach(chef, owner)
    local missing = {}
    setmetatable(chef, {
      __index = function(_, key)
        local id = tostring(key)
        if not missing[id] then
          missing[id] = true
          say(owner .. " chef." .. id .. " is not provided; the mod keeps running")
        end
        return function() return nil end
      end,
    })
    return chef
  end

  add_option("ordnance", "menu_key", { type = "key", label = "Menu key", default = "f10", menu = true, _title = "Ordnance" })
  say("options menu: " .. menu_key())

  -- The other loaders' menus are two globals any mod can call. Nothing here
  -- is named after a particular mod. A mod written today or later gets a row
  -- by calling these, the same way the mods already installed do.
  local function as_text(v)
    if type(v) == "string" then return v end
    if type(v) == "function" then
      local ok, s = pcall(v)
      if ok and type(s) == "string" then return s end
    end
    return nil
  end

  local MOM_PER, MOM_MODS = 32, 112
  local mom_rows, mom_meta, mom_pending, mom_per = {}, {}, {}, {}
  local mom_n, mom_mods = 0, 0

  local function mom_describe(spec)
    if type(spec) ~= "table" then return nil, "invalid option registration" end
    local ty = spec.type
    local label = as_text(spec.label)
    if label == nil or string.find(label, "%S") == nil or #label > 127 then return nil, "invalid option registration" end
    if ty ~= "toggle" and ty ~= "choice" and ty ~= "slider" then return nil, "type must be toggle, choice or slider" end
    if ty == "choice" and (type(spec.choices) ~= "table" or #spec.choices < 2 or #spec.choices > 16) then
      return nil, "choices must list 2 to 16 names"
    end
    if ty == "slider" and not (finite(spec.min) and finite(spec.max) and spec.min < spec.max) then
      return nil, "slider needs min < max"
    end
    local step = ty == "slider" and spec.step or nil
    if step == 0 then step = nil end
    if step ~= nil and not (finite(step) and step > 0 and step <= spec.max - spec.min) then
      return nil, "slider needs 0 < step <= max - min"
    end
    local hint = type(spec.description) == "string" and #spec.description <= 200 and spec.description or nil
    local s = { type = ty, label = label, default = spec.default, choices = spec.choices, min = spec.min, max = spec.max, step = step, hint = hint }
    local meta = { kind = ty, default = clean(s, ty == "choice" and (spec.default or 1) or spec.default), min = spec.min, max = spec.max, step = step }
    if ty == "choice" then meta.n = #spec.choices end
    return { spec = s, meta = meta }
  end

  local function mom_same(a, b)
    if a.kind ~= b.kind or a.default ~= b.default then return false end
    if a.kind == "choice" then return a.n == b.n end
    if a.kind == "slider" then return a.min == b.min and a.max == b.max and a.step == b.step end
    return true
  end

  local mom = {
    api = 1, version = 3, max_mods = MOM_MODS, max_options = MOM_PER, revision = "ordnance-loader-1",
    window = "Ordnance options menu",
  }
  function mom.register_option(id, spec)
    if not loose_id(id) then return false, "invalid option registration" end
    local parsed, why = mom_describe(spec)
    if not parsed then return false, why end
    local had = mom_rows[id]
    if had then
      if mom_same(mom_meta[id], parsed.meta) then return true end
      return false, "option already registered differently"
    end
    if spec.mod_id ~= nil and (type(spec.mod_id) ~= "string" or #spec.mod_id > 64 or string.match(spec.mod_id, "^[%w_%.%-/:]+$") == nil) then
      return false, "invalid mod_id"
    end
    local title = as_text(spec.mod) or "Options"
    local owner = spec.mod_id or title
    if mom_n >= MOM_PER * MOM_MODS then return false, "register_option: " .. (MOM_PER * MOM_MODS) .. " options already" end
    if (mom_per[owner] or 0) >= MOM_PER then return false, "mod already has " .. MOM_PER .. " options" end
    if mom_per[owner] == nil and mom_mods >= MOM_MODS then return false, "all " .. MOM_MODS .. " mod categories are in use" end
    parsed.spec._title = title
    local row, err = add_option(owner, id, parsed.spec, true)
    if not row then return false, err end
    mom_rows[id], mom_meta[id] = row, parsed.meta
    mom_n = mom_n + 1
    if mom_per[owner] == nil then mom_mods = mom_mods + 1 end
    mom_per[owner] = (mom_per[owner] or 0) + 1
    local waiting = mom_pending[id]
    mom_pending[id] = nil
    if waiting then
      for i = 1, #waiting do row.changed[#row.changed + 1] = waiting[i] end
    end
    say("option " .. id .. " (" .. title .. ")")
    return true
  end
  function mom.get(id)
    local row = mom_rows[id]
    if row then return row.value end
  end
  function mom.set(id, value)
    local row = mom_rows[id]
    if row == nil then return false, "unknown option" end
    local meta = mom_meta[id]
    if meta and meta.kind ~= "toggle" and type(value) ~= "number" then return false, "invalid value" end
    if meta and meta.kind == "toggle" and type(value) ~= "boolean" then return false, "invalid value" end
    set_value(row, value, true)
    return true
  end
  function mom.on_change(id, fn)
    if type(id) ~= "string" or type(fn) ~= "function" then return false, "invalid callback" end
    local row = mom_rows[id]
    local wrapped = function(v) return fn(v, id) end
    if row then
      row.changed[#row.changed + 1] = wrapped
      return true
    end
    local p = mom_pending[id] or {}
    if #p >= 64 then return false end
    p[#p + 1] = wrapped
    mom_pending[id] = p
    return true
  end
  function mom.ready() return true end
  rawset(_G, "ModOptionsMenu", mom)

  local function mouse_held(name)
    local which = ({ ["mouse 3"] = "middle", ["mouse 4"] = "extra_1", ["mouse 5"] = "extra_2" })[name]
    local S = stingray()
    local M = S and S.Mouse
    if which == nil or type(M) ~= "table" or type(M.button_index) ~= "function" or type(M.button) ~= "function" then
      return false
    end
    local ok, idx = pcall(M.button_index, which)
    if not ok or idx == nil then ok, idx = pcall(M.button_index, name) end
    if not ok or idx == nil then return false end
    local ok2, v = pcall(M.button, idx)
    return ok2 and (v == true or (type(v) == "number" and v > 0.5))
  end

  local function control_held(name)
    if open or capture then return false end
    if type(name) ~= "string" or name == "" or name == "off" then return false end
    if string.sub(name, 1, 6) == "mouse " then return mouse_held(name) end
    if string.find(name, "+", 1, true) then return binding_down(name, false) end
    return key_down(name)
  end

  -- A default is a key name, or { button, device, trigger, modifiers }, or a list of those.
  local function binding_spec(spec)
    if spec == nil then return "off", "press" end
    if type(spec) == "string" then return string.lower(spec), "press" end
    if type(spec) ~= "table" then return "off", "press" end
    local list = (spec.button == nil and type(spec[1]) ~= "nil") and spec or { spec }
    if spec.button == nil and spec[1] == nil then return "off", "press" end
    for i = 1, #list do
      local x = list[i]
      local button, device, trigger, front = x, "keyboard", "press", ""
      local known = true
      if type(x) == "table" then
        button, device, trigger = x.button, x.device or "keyboard", x.trigger or "press"
        if type(x.modifiers) == "table" then
          local has = {}
          for j = 1, #x.modifiers do
            local m = type(x.modifiers[j]) == "string" and string.lower(x.modifiers[j]) or ""
            if m == "control" then m = "ctrl" end
            if m == "ctrl" or m == "shift" or m == "alt" then has[m] = true else known = false end
          end
          for _, m in ipairs({ "ctrl", "shift", "alt" }) do if has[m] then front = front .. m .. "+" end end
        end
      end
      if known and type(button) == "string" and (trigger == "press" or trigger == "hold" or trigger == "release") then
        button = string.lower(button)
        if device == "mouse" then
          button = ({ middle = "mouse 3", extra_1 = "mouse 4", extra_2 = "mouse 5" })[button]
        elseif device ~= "keyboard" then
          button = nil
        end
        if button then return front .. button, trigger end
      end
    end
    return "off", "press"
  end

  local bindings = {}
  local mbm = {
    api = 1, version = 4, loader = "ordnance-loader-1", capacity = 36 * MOM_MODS, window = "Ordnance options menu",
    extended = { devices = { "keyboard", "mouse" }, triggers = { "press", "release", "hold" } },
  }
  function mbm.register_binding(id, label, slot, options)
    if not loose_id(id) then return false, "invalid binding registration" end
    if slot ~= nil and type(slot) ~= "number" then return false, "invalid binding registration" end
    if options ~= nil and type(options) ~= "table" then return false, "invalid binding registration" end
    label = as_text(label)
    if label == nil or string.find(label, "%S") == nil or #label > 127 then return false, "invalid binding registration" end
    local category = nil
    if options and options.category ~= nil then
      if type(options.category) ~= "string" or string.find(options.category, "%S") == nil or #options.category > 64 then
        return false, "invalid binding category"
      end
      category = options.category
    end
    local had = bindings[id]
    if had then
      if had.label == label and had.slot == slot then return true end
      return false, "binding already registered differently"
    end
    local name, trigger = binding_spec(options and options.default)
    local owner = category or "Bindings"
    local row, err = add_option(owner, id, { type = "key", default = name, label = label, _title = owner }, true)
    if not row then return false, err end
    bindings[id] = { row = row, label = label, slot = slot, trigger = trigger }
    say("binding " .. id .. " (" .. owner .. ")")
    return true
  end
  function mbm.is_down(id)
    local b = bindings[id]
    if b == nil then return nil end
    -- One answer per frame. A mod that asks twice, or asks and then polls, sees the same edge.
    if b.frame ~= menu_frame then
      local held = control_held(b.row.value)
      local was = b.was == true
      b.was, b.frame = held, menu_frame
      if b.trigger == "hold" then b.down = held
      elseif b.trigger == "release" then b.down = was and not held
      else b.down = held and not was end
    end
    return b.down
  end
  function mbm.ready() return true end
  function mbm.poll(ids, out)
    if type(ids) ~= "table" or type(out) ~= "table" then return false, "invalid poll arguments" end
    local fields = { "down", "pressed", "released", "last" }
    for i = 1, #fields do
      local f = fields[i]
      if out[f] == nil then out[f] = {} elseif type(out[f]) ~= "table" then return false, "invalid poll arguments" end
    end
    for i = 1, #ids do
      local down = mbm.is_down(ids[i])
      local was = out.last[i] == true
      out.down[i], out.pressed[i], out.released[i], out.last[i] = down, down == true and not was, was and down ~= true, down == true
    end
    return true
  end
  function mbm.set_binding(id, spec)
    local b = bindings[id]
    if b == nil then return false, "not an extended binding" end
    local name
    if spec == nil then name = b.row.default
    elseif type(spec) == "table" and spec.button == nil and spec[1] == nil then name = "off"
    else name = binding_spec(spec) end
    set_value(b.row, name, true)
    return true
  end
  function mbm.binding(id)
    local b = bindings[id]
    if b == nil then return nil end
    local name = b.row.value
    if name == "off" then return {} end
    local device = string.sub(name, 1, 6) == "mouse " and "mouse" or "keyboard"
    return { { device, name, modifiers = {}, trigger = b.trigger } }
  end
  function mbm.binding_info(id)
    local b = bindings[id]
    if b == nil then return nil end
    local v, d = b.row.value, b.row.default
    local state = "set"
    if v == "off" and d ~= "off" then state = "cleared"
    elseif v == d then state = "default" end
    return { backend = "extended", state = state }
  end
  rawset(_G, "ModBindingsMenu", mbm)
  say("ModOptionsMenu ready")
  say("ModBindingsMenu ready")

  local function use_options(saved)
    option_sets = type(saved) == "table" and saved or {}
  end

  local function describe()
    local parts = {}
    for i = 1, #groups do
      parts[#parts + 1] = groups[i].title .. " (" .. #groups[i].rows .. ")"
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, ", ")
  end

  local function blocking() return open or capture ~= nil end

  return { chef_for = chef_for, adopt = runtime.adopt, update = update, render = render, use_options = use_options, describe = describe, release = release, blocking = blocking, emit = function(event, ...) if runtime and runtime.emit then runtime.emit(event, ...) end end }
end)()

-- Mods hook update while init runs, and they keep the function they find.
-- The menu is installed after those hooks, so it calls them and they call
-- the game. Installing it earlier makes the two call each other until the
-- game dies.
local call_update, call_render
local menu_update_said = false
local closing = false
local function ran_too_long(err)
  return string.find(tostring(err), "ran too long", 1, true) ~= nil
end
local function on_update(dt)
  if closing then return end
  if not menu_update_said then
    menu_update_said = true
    say("menu update live")
    flush()
  end
  local ok, err = pcall(menu_api.update, dt)
  if not ok then say("menu: " .. tostring(err)) end
  -- The game's own update lives in this chain. Do not time it out and do not
  -- drop it: a long frame mid-mission was leaving the mission frozen.
  if type(call_update) == "function" and call_update ~= on_update then return call_update(dt) end
end
local function on_render(...)
  if closing then return end
  if type(call_render) == "function" and call_render ~= on_render then call_render(...) end
  local ok, err = pcall(menu_api.render)
  if not ok then say("menu draw: " .. tostring(err)) end
end
local function adopt_frame()
  local now_u, now_r = rawget(_G, "update"), rawget(_G, "render")
  if type(now_u) == "function" and now_u ~= on_update then call_update = now_u end
  if type(now_r) == "function" and now_r ~= on_render then call_render = now_r end
  rawset(_G, "update", on_update)
  rawset(_G, "render", on_render)
end

local function read_entry(entry)
  local ok, file = pcall(io.open, entry.path, "rb")
  if not ok or file == nil then return nil, "cannot open" end
  file:seek("set", entry.at)
  local source = file:read(entry.size)
  pcall(function() file:close() end)
  if source == nil or #source ~= entry.size then return nil, "short read" end
  return source
end

local function skip_reason(source)
  if string.find(source, "@@ORDNANCE@@", 1, true) then return "this loader" end
  local head = string.sub(source, 1, 1600)
  if string.find(head, "--@@LOADER@@", 1, true) then return "another loader" end
  -- The loader's own file names itself on the first line. A mod that
  -- mentions Chef, Rat, or Boot Mod Loader further down is still a mod.
  local first = string.match(source, "^([^\r\n]*)") or ""
  if string.find(first, "Chef Shared Loader", 1, true)
    or string.find(first, "Boot Mod Loader", 1, true)
    or string.find(first, "Rat's Shared Loader", 1, true) then
    return "another loader"
  end
  if string.find(source, "require(\"ffi\")", 1, true) or string.find(source, "require('ffi')", 1, true) then
    return "needs ffi, which this game does not have"
  end
  return nil
end

local function traceback(err)
  local debug_lib = rawget(_G, "debug")
  local tb = type(debug_lib) == "table" and debug_lib.traceback
  if type(tb) == "function" then
    local ok, text = pcall(tb, tostring(err), 2)
    if ok then return text end
  end
  return tostring(err)
end

local function wants_chef(source)
  return string.find(source, "local%s+chef%s*=%s*%.%.%.") ~= nil
    or string.find(source, "\nlocal%s+chef%s*=%s*%.%.%.") ~= nil
end

local function run_addon(entry)
  local source, why = read_entry(entry)
  if source == nil then
    say(entry.name .. ": " .. tostring(why))
    return
  end
  local skip = skip_reason(source)
  if skip ~= nil then
    say(entry.name .. ": skipped (" .. skip .. ")")
    return
  end
  local chunk, err = loadstring(source, "@" .. entry.name)
  if chunk == nil then
    say(entry.name .. " (patch_" .. entry.patch .. "): does not compile: " .. tostring(err))
    return
  end
  local clock0 = os.clock()
  local ran, result
  dog_enter(entry.name, 10)
  if wants_chef(source) then
    local mine = menu_api.chef_for(entry.name)
    ran, result = xpcall(function() return chunk(mine) end, traceback)
  else
    ran, result = xpcall(chunk, traceback)
  end
  dog_leave()
  local took = (os.clock() - clock0) * 1000
  if ran then
    if type(package) == "table" and type(package.loaded) == "table" and package.loaded[entry.name] == nil then
      package.loaded[entry.name] = (result == nil) and true or result
    end
    local rat = string.find(source, "@loader rat", 1, true) and ", @loader rat" or ""
    say(string.format("%s (patch_%d, %d bytes%s): loaded in %.0f ms", entry.name, entry.patch, #source, rat, took))
    if type(result) == "table" then
      menu_api.adopt(entry.name, result)
    end
  else
    say(entry.name .. " (patch_" .. entry.patch .. "): FAILED: " .. tostring(result))
  end
end

local CALLBACKS = { "init", "update", "render", "shutdown" }

local function run_guest(entry)
  local source, why = read_entry(entry)
  if source == nil then
    say(entry.kind .. " " .. entry.name .. ": " .. tostring(why))
    return
  end
  local skip = skip_reason(source)
  if skip ~= nil then
    say(entry.name .. ": skipped (" .. skip .. ")")
    return
  end
  local chunk, err = loadstring(source, "@" .. entry.name)
  if chunk == nil then
    say(entry.name .. ": does not compile: " .. tostring(err))
    return
  end
  local before = {}
  for _, key in ipairs(CALLBACKS) do before[key] = rawget(_G, key) end
  -- A boot that already calls the update it found must not have that call
  -- made a second time by the wrapper below.
  local chains = string.find(source, "prev.update", 1, true) ~= nil
    or string.find(source, "rawget(_G, 'update')", 1, true) ~= nil
    or string.find(source, "rawget(_G, \"update\")", 1, true) ~= nil
  local mine = nil
  if wants_chef(source)
    or string.find(source, "global('chef')", 1, true)
    or string.find(source, "global(\"chef\")", 1, true) then
    mine = menu_api.chef_for(entry.name)
  end
  local saved_chef = rawget(_G, "chef")
  if mine ~= nil then rawset(_G, "chef", mine) end
  dog_enter(entry.name, 10)
  local ran, result
  if mine ~= nil then
    ran, result = xpcall(function() return chunk(mine) end, traceback)
  else
    ran, result = xpcall(chunk, traceback)
  end
  if mine ~= nil then rawset(_G, "chef", saved_chef) end
  dog_leave()
  if not ran then
    say(entry.name .. ": FAILED: " .. tostring(result))
    for _, key in ipairs(CALLBACKS) do rawset(_G, key, before[key]) end
    return
  end
  local names = {}
  for _, key in ipairs(CALLBACKS) do
    local now = rawget(_G, key)
      if type(now) == "function" and now ~= before[key] then
      local captured = now
      if key == "init" then
        rawset(_G, key, before[key])
        dog_enter(entry.name .. " init", 10)
        local ok, problem = pcall(captured)
        dog_leave()
        if not ok then say(entry.name .. " init: " .. tostring(problem)) end
      else
        local previous = before[key]
        if previous == on_update then previous = call_update end
        if previous == on_render then previous = call_render end
        if type(previous) ~= "function" then previous = nil end
        rawset(_G, key, function(...)
          local ok, problem = pcall(captured, ...)
          if not ok then
            say(entry.name .. " " .. key .. ": " .. tostring(problem))
            if ran_too_long(problem) then error(problem, 0) end
          end
          if not chains and previous ~= nil then return previous(...) end
        end)
      end
      names[#names + 1] = key
    end
  end
  say(string.format("%s %s (patch_%d): runs %s", entry.kind, entry.name, entry.patch,
    #names > 0 and table.concat(names, ", ") or "no callback"))
  if type(result) == "table" then menu_api.adopt(entry.name, result) end
end

local function run_options(entry)
  local source, why = read_entry(entry)
  if source == nil then
    say("options " .. entry.name .. ": " .. tostring(why))
    return
  end
  local chunk, err = loadstring(source, "@" .. entry.name)
  if chunk == nil then
    say("options " .. entry.name .. ": does not compile: " .. tostring(err))
    return
  end
  local ran, result
  dog_enter(entry.name, 10)
  if wants_chef(source) then
    local mine = menu_api.chef_for(entry.name)
    ran, result = xpcall(function() return chunk(mine) end, traceback)
  else
    ran, result = xpcall(chunk, traceback)
  end
  dog_leave()
  if not ran then
    say("options " .. entry.name .. ": FAILED: " .. tostring(result))
    return nil
  end
  if type(package) == "table" and type(package.loaded) == "table" then
    package.loaded[entry.name] = (result == nil) and true or result
  end
  say("options " .. entry.name .. " (patch_" .. entry.patch .. "): loaded")
  return result
end

-- Option files return tables. One of them names the rows the menu shows.
-- Later patches win on the same field. Nested tables combine.
local function merge_into(dst, src)
  if type(src) ~= "table" then return dst end
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge_into(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function hook_shutdown()
  local previous = rawget(_G, "shutdown")
  if type(previous) ~= "function" then previous = nil end
  local function shutdown_fn(...)
    if closing then
      if previous ~= nil then return previous(...) end
      return
    end
    closing = true
    -- The count hook and a live screen GUI both stall the engine while it
    -- tears the world down. Let go of them before any mod's own shutdown.
    dog_disarm()
    if type(menu_api.release) == "function" then pcall(menu_api.release) end
    say("shutdown")
    flush()
    local results, failed = { n = 0 }, nil
    if previous ~= nil then
      local packed = { pcall(previous, ...) }
      if packed[1] then
        results = { n = #packed - 1 }
        for i = 2, #packed do results[i - 1] = packed[i] end
      else
        failed = packed[2]
        say("shutdown: " .. tostring(failed))
        flush()
      end
    end
    for i, fn in ipairs(on_shutdown) do
      local ran, problem = pcall(fn)
      if not ran then say("on_shutdown " .. i .. ": " .. tostring(problem)) end
    end
    flush()
    return unpack(results, 1, results.n)
  end
  rawset(_G, "shutdown", shutdown_fn)
end

-- `-- @requires` and `-- @after` are how a Rat mod names what has to start
-- first. Patch order is the tiebreak. A missing requirement is logged and
-- the mod still starts, so its own error is the one in the log.
local function header_needs(source)
  local needs, lines = {}, 0
  for line in string.gmatch(string.sub(source or "", 1, 2000), "[^\r\n]+") do
    lines = lines + 1
    if lines > 30 then break end
    if string.sub(line, 1, 2) ~= "--" then break end
    local dep = string.match(line, "^%-%- @requires%s+(%S+)")
      or string.match(line, "^%-%- @after%s+(%S+)")
    if dep ~= nil then needs[#needs + 1] = dep end
  end
  return needs
end

local function order_addons(entries)
  local list = {}
  for i, entry in ipairs(entries) do list[i] = entry end
  table.sort(list, function(a, b)
    if a.patch ~= b.patch then return a.patch < b.patch end
    return tostring(a.name) < tostring(b.name)
  end)
  local index, needs, said = {}, {}, false
  for i, entry in ipairs(list) do index[entry.name] = i end
  for _, entry in ipairs(list) do
    local source = read_entry(entry)
    local deps = {}
    for _, dep in ipairs(header_needs(source)) do
      if index[dep] then deps[#deps + 1] = dep
      else
        say(entry.name .. " requires " .. dep .. ", which is not deployed")
        said = true
      end
    end
    needs[entry.name] = deps
  end
  local ordered, state = {}, {}
  local function visit(name)
    if state[name] == "done" then return end
    if state[name] == "busy" then
      say(name .. ": requirement cycle, patch order kept")
      said = true
      return
    end
    state[name] = "busy"
    for _, dep in ipairs(needs[name] or {}) do visit(dep) end
    state[name] = "done"
    ordered[#ordered + 1] = list[index[name]]
  end
  for _, entry in ipairs(list) do visit(entry.name) end
  if said then flush() end
  return ordered
end

-- Rat's engine object, one per mod. Each call checks its arguments and returns
-- a specific answer. A fresh closure that ignores its arguments is not that.
local rat_cape_owners = setmetatable({}, { __mode = "k" })
local function bind_rat_surface(N, mod, known_world, frame_of)
  local CAPE_UNITS = { ["3c33cf10a26cbb3e"] = true, ["ea846ef460cc5ba0"] = true }
  local CAPE_BONES = {
    chest = true, cape1 = true, cape2 = true, cape3 = true, cape4 = true,
    cape5 = true, cape6 = true, cape7 = true, cape8 = true,
  }
  local CAPE_SHIFT = 0.12
  local CAPE_TYPES = {
    ["3c33cf10a26cbb3e"] = { slot = "ffcdb65b", source = "7531dea9b2a2b888", positions = 3 },
    ["ea846ef460cc5ba0"] = { slot = "3d35eb9e", source = "38bd5d2916d3ab44", positions = 3 },
  }
  local CAPE_FIELDS = { "material_lut", "cape_lut", "cape_gradient", "decal_sheet", "cape_scalar_fields" }
  local CAPE_FIELD = {}
  for i = 1, #CAPE_FIELDS do CAPE_FIELD[CAPE_FIELDS[i]] = true end
  local TEXTURE_DELAY, TEXTURE_BYTES, TEXTURE_LIMIT = 2, 2040, 8192

  mod.rat_meshes = mod.rat_meshes or {}
  mod.rat_materials = mod.rat_materials or {}
  mod.rat_versions = mod.rat_versions or {}
  mod.spawned_at = mod.spawned_at or {}
  mod.cape_shift = mod.cape_shift or {}
  mod.rebound = mod.rebound or {}
  mod.palette_aliases = mod.palette_aliases or {}
  mod.textures = mod.textures or {}
  mod.tex_slots = mod.tex_slots or {}
  mod.cape_records = mod.cape_records or {}
  mod.cape_blocked = mod.cape_blocked or {}
  mod.lobby_handles = mod.lobby_handles or {}

  local function kind_of(value)
    local t = type(value)
    if t ~= "userdata" then return t end
    local ok, text = pcall(tostring, value)
    if not ok or type(text) ~= "string" then return "userdata" end
    return string.match(text, "^%[(%a[%w_]*)") or string.match(text, "^(%a[%w_]*)%(") or "userdata"
  end
  local function whole(n, lo, hi)
    return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
  end
  local function hex16(s)
    return type(s) == "string" and #s == 16 and string.match(s, "^[0-9a-f]+$") ~= nil
  end
  local function frame()
    local n = frame_of()
    if type(n) ~= "number" then return 0 end
    return n
  end
  local function engine(ns, name)
    local S = rawget(_G, "stingray")
    local box = type(S) == "table" and S[ns]
    local fn = type(box) == "table" and box[name]
    if type(fn) ~= "function" then return nil end
    return fn
  end
  local function packed(fn, ...)
    local function count(...) return select("#", ...), ... end
    return count(pcall(fn, ...))
  end
  local function alive(u)
    if kind_of(u) ~= "Unit" then return false end
    local fn = engine("Unit", "alive")
    if not fn then return false end
    local n, ok, v = packed(fn, u)
    return ok and n >= 2 and v == true
  end
  local function node_ok(u, i)
    local fn = engine("Unit", "num_scene_graph_items")
    if not fn then return false end
    local n, ok, count = packed(fn, u)
    return ok and whole(i, 1, (n >= 2 and count) or 0)
  end
  local function id64(text)
    local S = rawget(_G, "stingray")
    local from = type(S) == "table" and type(S.IdString64) == "table" and S.IdString64.from_hex
    if type(from) ~= "function" or type(text) ~= "string" then return nil end
    local n, ok, id = packed(from, string.lower(text))
    if ok and n >= 2 then return id end
  end
  local function id32(text)
    local S = rawget(_G, "stingray")
    local from = type(S) == "table" and type(S.IdString32) == "table" and S.IdString32.from_hex
    if type(from) ~= "function" or type(text) ~= "string" then return nil end
    local n, ok, id = packed(from, string.lower(text))
    if ok and n >= 2 then return id end
  end
  local function to_hex(value)
    if type(value) ~= "userdata" then return nil end
    local S = rawget(_G, "stingray")
    local fn = type(S) == "table" and type(S.IdString64) == "table" and S.IdString64.to_hex
    if type(fn) ~= "function" then return nil end
    local n, ok, hex = packed(fn, value)
    if ok and n >= 2 and type(hex) == "string" then return string.lower(hex) end
  end
  local function to_hex32(value)
    if type(value) ~= "userdata" then return nil end
    local S = rawget(_G, "stingray")
    local fn = type(S) == "table" and type(S.IdString32) == "table" and S.IdString32.to_hex
    if type(fn) ~= "function" then return nil end
    local n, ok, hex = packed(fn, value)
    if ok and n >= 2 and type(hex) == "string" then return string.lower(hex) end
  end
  local function vec3(x, y, z)
    local S = rawget(_G, "stingray")
    local V = type(S) == "table" and S.Vector3
    if type(V) ~= "function" and type(V) ~= "table" then return nil end
    local n, ok, v = packed(V, x, y, z)
    if ok and n >= 2 then return v end
  end
  local function vec_xyz(v)
    local S = rawget(_G, "stingray")
    local V = type(S) == "table" and S.Vector3
    if type(V) == "table" and type(V.x) == "function" then
      local nx, okx, x = packed(V.x, v)
      local ny, oky, y = packed(V.y, v)
      local nz, okz, z = packed(V.z, v)
      if okx and oky and okz and nx >= 2 and ny >= 2 and nz >= 2 and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
      end
    end
    if type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then
      return v.x, v.y, v.z
    end
    local to = (type(V) == "table" or type(V) == "function") and V.to_elements
    if type(to) ~= "function" then return nil end
    local n, ok, x, y, z = packed(to, v)
    if ok and n >= 4 and type(x) == "number" then return x, y, z end
  end
  local function resource(kind, id)
    local can = engine("Application", "can_get")
    if not can then return nil end
    if kind_of(id) == "IdString64" then
      local n, ok, yes = packed(can, kind, id)
      if ok and n >= 2 and yes == true then return id end
      return nil
    end
    if type(id) ~= "string" or id == "" then return nil end
    local converted
    if string.match(id, "^%x+$") and #id == 16 then converted = id64(id)
    else
      local S = rawget(_G, "stingray")
      local ctor = type(S) == "table" and S.IdString64
      if type(ctor) == "function" or type(ctor) == "table" then
        local n, ok, made = packed(ctor, id)
        if ok and n >= 2 then converted = made end
      end
    end
    if converted == nil then return nil end
    local n, ok, yes = packed(can, kind, converted)
    if ok and n >= 2 and yes == true then return converted end
  end
  local function translation_of(m)
    local ok, text = pcall(tostring, m)
    local body = ok and type(text) == "string" and string.match(text, "^Matrix4x4%((.*)%)%s*$")
    if not body then return nil end
    local nums = {}
    for v in string.gmatch(body, "[-+]?%d+%.?%d*[eE]?[-+]?%d*") do nums[#nums + 1] = tonumber(v) end
    if #nums ~= 16 then return nil end
    return nums[13], nums[14], nums[15]
  end
  local function mesh_ok(m)
    local entry = mod.rat_meshes[m]
    return entry and entry.frame == frame() and alive(entry.unit) and not mod.cape_blocked[entry.unit]
  end
  local function material_ok(mat)
    local entry = mod.rat_materials[mat]
    return entry and entry.frame == frame() and alive(entry.unit) and not mod.cape_blocked[entry.unit]
      and entry.version == (mod.rat_versions[entry.unit] or 0)
  end

  local function install_units()
    N.Unit.alive = function(u)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      return alive(u)
    end
    local reads = { "num_scene_graph_items", "num_meshes", "resource_name", "world", "id", "has_animation_state_machine" }
    for i = 1, #reads do
      local name = reads[i]
      N.Unit[name] = function(u)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        local fn = engine("Unit", name)
        if not fn then return nil, "missing" end
        local n, ok, a, b = packed(fn, u)
        if not ok then return nil, a end
        return a, b
      end
    end
    local posed = { "world_position", "world_rotation", "world_pose", "local_position", "local_rotation", "local_scale", "local_pose" }
    for i = 1, #posed do
      local name = posed[i]
      N.Unit[name] = function(u, node)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        if node == nil then node = 1 end
        if not node_ok(u, node) then return nil, "no such node" end
        local fn = engine("Unit", name)
        if not fn then return nil, "missing" end
        local n, ok, a = packed(fn, u, node)
        if not ok then return nil, a end
        return a
      end
    end
    N.Unit.has_node = function(u, name)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if type(name) ~= "string" then return nil, "node name is not a string" end
      local fn = engine("Unit", "has_node")
      if not fn then return nil, "missing" end
      local n, ok, a = packed(fn, u, name)
      if not ok then return nil, a end
      return a
    end
    N.Unit.node = function(u, name)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if type(name) ~= "string" then return nil, "node name is not a string" end
      local has = engine("Unit", "has_node")
      if not has then return nil, "missing" end
      local nh, okh, yes = packed(has, u, name)
      if not okh then return nil, yes end
      if not (nh >= 2 and yes) then return nil, "no such node" end
      local fn = engine("Unit", "node")
      if not fn then return nil, "missing" end
      local n, ok, a = packed(fn, u, name)
      if not ok then return nil, a end
      return a
    end
    N.Unit.mesh = function(u, i)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if mod.cape_blocked[u] then return nil, "native cape reads require a fresh private transaction" end
      local count_fn = engine("Unit", "num_meshes")
      local mesh_fn = engine("Unit", "mesh")
      if not count_fn or not mesh_fn then return nil, "missing" end
      local nc, okc, count = packed(count_fn, u)
      if not okc or not whole(i, 1, (nc >= 2 and count) or 0) then return nil, "no such mesh" end
      local n, ok, m = packed(mesh_fn, u, i)
      if not ok then return nil, m end
      if m ~= nil then mod.rat_meshes[m] = { unit = u, frame = frame() } end
      return m
    end
    N.Unit.set_unit_visibility = function(u, visible)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if type(visible) ~= "boolean" then return nil, "visibility is not a boolean" end
      local fn = engine("Unit", "set_unit_visibility")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, u, visible)
      if not ok then return nil, err end
      if mod.owned[u] == nil then mod.hidden[u] = (not visible) or nil end
      return true
    end
    N.Unit.set_mesh_visibility = function(u, i, visible)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if mod.owned[u] == nil then return nil, "unit is not owned by this mod" end
      local count_fn = engine("Unit", "num_meshes")
      if not count_fn then return nil, "missing" end
      local nc, okc, count = packed(count_fn, u)
      if not okc or not whole(i, 1, (nc >= 2 and count) or 0) then return nil, "no such mesh" end
      if type(visible) ~= "boolean" then return nil, "visibility is not a boolean" end
      local fn = engine("Unit", "set_mesh_visibility")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, u, i, visible)
      if not ok then return nil, err end
      return true
    end
    local setters = {
      { "set_local_position", "Vector3" },
      { "set_local_rotation", "Quaternion", "Vector4" },
      { "set_local_scale", "Vector3" },
    }
    for i = 1, #setters do
      local name, want, alias = setters[i][1], setters[i][2], setters[i][3]
      N.Unit[name] = function(u, node, value)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        if mod.owned[u] == nil then return nil, "unit is not owned by this mod" end
        if not node_ok(u, node) then return nil, "no such node" end
        local got = kind_of(value)
        if got ~= want and got ~= alias then return nil, "value is not a " .. want end
        local fn = engine("Unit", name)
        if not fn then return nil, "missing" end
        local n, ok, err = packed(fn, u, node, value)
        if not ok then return nil, err end
        return true
      end
    end
    N.Unit.bones = function(u)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      local res_fn = engine("Unit", "resource_name")
      if not res_fn then return nil, "missing" end
      local nr, okr, res = packed(res_fn, u)
      local hex = okr and nr >= 2 and to_hex(res)
      local allowed = false
      if hex and type(mod.bones) == "table" then
        for i = 1, #mod.bones do
          if string.lower(mod.bones[i]) == hex then allowed = true break end
        end
      end
      if not allowed then return nil, "unit resource not declared for bone names" end
      local fn = engine("Unit", "bones")
      if not fn then return nil, "missing" end
      local n, ok, names = packed(fn, u)
      if not ok then return nil, names end
      if type(names) ~= "table" then return nil, "unobserved return shape" end
      return names
    end
    N.Unit.set_material_at = function(u, i, j, material)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if mod.cape_blocked[u] then return nil, "use the native cape transaction or restoration" end
      local meshes_fn = engine("Unit", "num_meshes")
      local mesh_fn = engine("Unit", "mesh")
      local mats_fn = engine("Mesh", "num_materials")
      local slot_fn = engine("Mesh", "material_slot_id")
      local set_fn = engine("Unit", "set_material")
      if not meshes_fn or not mesh_fn or not mats_fn or not slot_fn or not set_fn then return nil, "missing" end
      local nc, okc, count = packed(meshes_fn, u)
      if not okc or not whole(i, 1, (nc >= 2 and count) or 0) then return nil, "no such mesh" end
      local nm, okm, mesh = packed(mesh_fn, u, i)
      if not okm or mesh == nil then return nil, "no such mesh" end
      local nj, okj, nmat = packed(mats_fn, mesh)
      if not okj or not whole(j, 1, (nj >= 2 and nmat) or 0) then return nil, "no such material position" end
      local res = resource("material", material)
      if not res then return nil, "material is not loaded" end
      local ns, oks, slot = packed(slot_fn, mesh, j)
      if not oks or slot == nil then return nil, "no such material position" end
      mod.rat_versions[u] = (mod.rat_versions[u] or 0) + 1
      local np, okp, previous = packed(set_fn, u, slot, res)
      if not okp then return nil, previous end
        if mod.owned[u] == nil and previous ~= nil then
          local prev = to_hex(previous)
          if prev and hex16(prev) then
            local list = mod.rebound[u] or {}
            mod.rebound[u] = list
            local key = i .. ":" .. j
            if list[key] == nil then list[key] = prev end
          end
        end
      return true
    end
  end

  local function install_mesh()
    N.Mesh.visibility = function(m)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not mesh_ok(m) then return nil, "mesh handle is stale or unknown" end
      local fn = engine("Mesh", "visibility")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, m)
      if not ok then return nil, v end
      if type(v) ~= "boolean" then return nil, "unobserved return shape" end
      return v
    end
    N.Mesh.num_materials = function(m)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not mesh_ok(m) then return nil, "mesh handle is stale or unknown" end
      local fn = engine("Mesh", "num_materials")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, m)
      if not ok then return nil, v end
      return v
    end
    N.Mesh.material = function(m, j)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not mesh_ok(m) then return nil, "mesh handle is stale or unknown" end
      local count_fn = engine("Mesh", "num_materials")
      local mat_fn = engine("Mesh", "material")
      if not count_fn or not mat_fn then return nil, "missing" end
      local nc, okc, count = packed(count_fn, m)
      if not okc or not whole(j, 1, (nc >= 2 and count) or 0) then return nil, "no such material" end
      local n, ok, mat = packed(mat_fn, m, j)
      if not ok then return nil, mat end
      if mat ~= nil then
        local unit = mod.rat_meshes[m].unit
        mod.rat_materials[mat] = { unit = unit, frame = frame(), version = mod.rat_versions[unit] or 0 }
      end
      return mat
    end
    N.Mesh.name = function(m)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not mesh_ok(m) then return nil, "stale or unknown mesh" end
      local fn = engine("Mesh", "name")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, m)
      if not ok then return nil, v end
      return v
    end
    N.Mesh.refresh_instance_hash = function(mesh)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local entry = mod.rat_meshes[mesh]
      if not mesh_ok(mesh) or not entry or mod.owned[entry.unit] == nil or mod.spawned_at[entry.unit] ~= frame() then
        return nil, "not an owned spawn-frame mesh"
      end
      local count_fn = engine("Mesh", "num_materials")
      local mat_fn = engine("Mesh", "material")
      local id_fn = engine("Material", "id64")
      local refresh = engine("Mesh", "refresh_instance_hash")
      if not count_fn or not mat_fn or not id_fn or not refresh then return nil, "missing" end
      local nc, okc, count = packed(count_fn, mesh)
      local private = false
      if okc and type(count) == "number" then
        for i = 1, count do
          local nm, okm, mat = packed(mat_fn, mesh, i)
          if okm and mat ~= nil then
            local ni, oki, id = packed(id_fn, mat)
            local hex = oki and ni >= 2 and to_hex(id)
            if hex and mod.palette_aliases[hex] then private = true end
          end
        end
      end
      if not private then return nil, "mesh has no registered private material" end
      local n, ok, value = packed(refresh, mesh)
      if not ok then return nil, value end
      if n ~= 2 or kind_of(value) ~= "MeshObject" then return nil, "unobserved return shape" end
      return true
    end
  end

  local function install_material()
    N.Material.id64 = function(mat)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not material_ok(mat) then return nil, "material handle is stale or unknown" end
      local fn = engine("Material", "id64")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, mat)
      if not ok then return nil, v end
      return v
    end
    local scalar = { { "set_scalar", "number" }, { "set_vector2", "Vector2" }, { "set_vector3", "Vector3" }, { "set_vector4", "Vector4" } }
    for i = 1, #scalar do
      local name, want = scalar[i][1], scalar[i][2]
      N.Material[name] = function(mat, variable, value)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not material_ok(mat) then return nil, "material handle is stale or unknown" end
        if type(variable) ~= "string" then return nil, "variable name is not a string" end
        if kind_of(value) ~= want then return nil, "value is not a " .. want end
        local fn = engine("Material", name)
        if not fn then return nil, "missing" end
        local n, ok, err = packed(fn, mat, variable, value)
        if not ok then return nil, err end
        return true
      end
    end
    N.Material.set_uint_vector = function(mat, variable, value)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not material_ok(mat) then return nil, "material handle is stale or unknown" end
      if type(variable) ~= "string" then return nil, "variable name is not a string" end
      if type(value) ~= "table" or #value < 1 or #value > 4 then
        return nil, "value is not a list of 1 to 4 integers"
      end
      local copy = {}
      for i = 1, #value do
        if not whole(value[i], 0, 4294967295) then return nil, "value is not a list of 1 to 4 integers" end
        copy[i] = value[i]
      end
      local fn = engine("Material", "set_uint_vector")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, mat, variable, copy)
      if not ok then return nil, err end
      return true
    end
    N.Material.set_texture = function(mat, variable, texture)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not material_ok(mat) then return nil, "material handle is stale or unknown" end
      if type(variable) ~= "string" then return nil, "variable name is not a string" end
      local res = resource("texture", texture)
      if not res then return nil, "texture is not loaded" end
      local fn = engine("Material", "set_texture")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, mat, variable, res)
      if not ok then return nil, err end
      return true
    end
    N.Material.private_aliases = function(list)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if type(list) ~= "table" then return nil, "expected a private ID list" end
      local set = {}
      for i = 1, #list do
        local entry = list[i]
        if type(entry) ~= "table" or not hex16(entry.id) or type(entry.slots) ~= "table" then
          return nil, "invalid private material declaration"
        end
        local slots = {}
        for j = 1, #entry.slots do
          local name = entry.slots[j]
          if type(name) ~= "string" or #name > 64 or string.match(name, "^[%w_]+$") == nil then
            return nil, "invalid texture slot name"
          end
          slots[name] = true
        end
        set[entry.id] = slots
      end
      mod.palette_aliases = set
      return true
    end
    local function private_slots(mat)
      local id_fn = engine("Material", "id64")
      if not id_fn then return nil end
      local n, ok, id = packed(id_fn, mat)
      local hex = ok and n >= 2 and to_hex(id)
      return hex and mod.palette_aliases[hex]
    end
    N.Material.set_private_texture = function(mat, variable, texture)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local entry = mod.rat_materials[mat]
      if not material_ok(mat) or not entry or mod.owned[entry.unit] == nil or mod.spawned_at[entry.unit] ~= frame() or not private_slots(mat) then
        return nil, "not a registered owned spawn-frame material"
      end
      if type(variable) ~= "string" then return nil, "variable name is not a string" end
      if not private_slots(mat)[variable] then return nil, "texture slot was not declared" end
      local created = type(texture) == "string" and mod.textures[texture]
      local fn, arg
      if created then
        if created.mod ~= mod or created.released then return nil, "texture is not loaded" end
        fn = engine("Material", "set_resource")
        arg = created.desc
        if not fn then return nil, "missing" end
      else
        arg = resource("texture", texture)
        if not arg then return nil, "texture is not loaded" end
        fn = engine("Material", "set_texture")
        if not fn then return nil, "missing" end
      end
      local n, ok, err = packed(fn, mat, variable, arg)
      if not ok then return nil, err end
      if n ~= 1 then return nil, "unobserved return shape" end
      local id_fn = engine("Material", "id64")
      local ni, oki, id = 0, false, nil
      if id_fn then ni, oki, id = packed(id_fn, mat) end
      local hex = oki and ni >= 2 and to_hex(id)
      if hex then
        local slot = hex .. "|" .. variable
        local before = mod.tex_slots[slot]
        if before ~= (created and texture or nil) then
          if before and mod.textures[before] then mod.textures[before].refs = mod.textures[before].refs - 1 end
          if created then created.refs = created.refs + 1 end
          mod.tex_slots[slot] = created and texture or nil
        end
      end
      return true
    end
    N.Material.reinitialize_shader = function(mat)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local entry = mod.rat_materials[mat]
      if not material_ok(mat) or not entry or mod.owned[entry.unit] == nil or mod.spawned_at[entry.unit] ~= frame() or not private_slots(mat) then
        return nil, "not an owned spawn-frame material"
      end
      local fn = engine("Material", "reinitialize_shader")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, mat)
      if not ok then return nil, err end
      if n ~= 1 then return nil, "unobserved return shape" end
      return true
    end
  end

  local function install_cape()
    N.Unit.shift_native_cape = function(u, offsets)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      if mod.owned[u] ~= nil then return nil, "unit is owned by this mod" end
      local res_fn = engine("Unit", "resource_name")
      if not res_fn then return nil, "missing" end
      local nr, okr, res = packed(res_fn, u)
      local hex = okr and nr >= 2 and to_hex(res)
      if not hex or not CAPE_UNITS[hex] then return nil, "not a native cape unit" end
      if offsets ~= nil and type(offsets) ~= "table" then return nil, "offsets are not a table" end
      local plan = {}
      for bone, v in pairs(offsets or {}) do
        if not CAPE_BONES[bone] then return nil, "not a cape anchor bone" end
        if type(v) ~= "table" or type(v[1]) ~= "number" or type(v[2]) ~= "number" or type(v[3]) ~= "number"
          or v[1] ~= v[1] or v[2] ~= v[2] or v[3] ~= v[3]
          or v[1] * v[1] + v[2] * v[2] + v[3] * v[3] > CAPE_SHIFT * CAPE_SHIFT then
          return nil, "offset out of range"
        end
        local has = N.Unit.has_node(u, bone)
        if has ~= true then return nil, "no such bone" end
        plan[bone] = v
      end
      local record = mod.cape_shift[u] or {}
      local pose_fn = engine("Unit", "local_pose")
      local node_fn = engine("Unit", "node")
      local set_fn = engine("Unit", "set_local_position")
      if not pose_fn or not node_fn or not set_fn then return nil, "missing" end
      for bone in pairs(plan) do
        if not record[bone] then
          local nn, okn, node = packed(node_fn, u, bone)
          local np, okp, pose = 0, false, nil
          if okn and nn >= 2 then np, okp, pose = packed(pose_fn, u, node) end
          local x, y, z
          if okp and np >= 2 then x, y, z = translation_of(pose) end
          if type(x) ~= "number" then return nil, "unreadable bone pose" end
          record[bone] = { x, y, z }
        end
      end
      for bone, base in pairs(record) do
        local v = plan[bone] or { 0, 0, 0 }
        local nn, okn, node = packed(node_fn, u, bone)
        local point = vec3(base[1] + v[1], base[2] + v[2], base[3] + v[3])
        if not okn or node == nil or not point then return nil, "unreadable bone pose" end
        local ns, oks, err = packed(set_fn, u, node, point)
        if not oks then return nil, err end
        if not plan[bone] then record[bone] = nil end
      end
      mod.cape_shift[u] = next(record) and record or nil
      return true
    end

    local function bind_source(u, record, material_hex)
      local set_fn = engine("Unit", "set_material")
      local slot = id32(record.slot)
      local mat = id64(material_hex)
      if not set_fn or not slot or not mat then return nil, "binding unavailable" end
      mod.rat_versions[u] = (mod.rat_versions[u] or 0) + 1
      local n, ok, previous = packed(set_fn, u, slot, mat)
      if not ok then return nil, previous end
      if n ~= 2 or kind_of(previous) ~= "IdString64" then return nil, "unexpected material binding return" end
      return to_hex(previous)
    end
    local function snapshot(u, spec)
      local positions = {}
      local mesh_count = engine("Unit", "num_meshes")
      local mesh_fn = engine("Unit", "mesh")
      local mat_count = engine("Mesh", "num_materials")
      local mat_fn = engine("Mesh", "material")
      local slot_fn = engine("Mesh", "material_slot_id")
      local id_fn = engine("Material", "id64")
      if not mesh_count or not mesh_fn or not mat_count or not mat_fn or not slot_fn or not id_fn then
        error("binding unavailable", 0)
      end
      local nc, okc, count = packed(mesh_count, u)
        if not okc or type(count) ~= "number" then error("cape material layout changed", 0) end
      for i = 1, count do
        local nm, okm, mesh = packed(mesh_fn, u, i)
        if not okm or mesh == nil then error("cape material layout changed", 0) end
        local nj, okj, nmat = packed(mat_count, mesh)
        if not okj or type(nmat) ~= "number" then error("cape material layout changed", 0) end
        for j = 1, nmat do
          local ns, oks, slot = packed(slot_fn, mesh, j)
          if oks and to_hex32(slot) == spec.slot then
            local nmatid, okid, mat = packed(mat_fn, mesh, j)
            local nid, oid, id = 0, false, nil
            if okid and nmatid >= 2 then nid, oid, id = packed(id_fn, mat) end
            if not oid or to_hex(id) ~= spec.source then error("cape source was replaced by another mod", 0) end
            positions[#positions + 1] = { i, j }
          end
        end
      end
      if #positions ~= spec.positions then error("cape material layout changed", 0) end
      return { slot = spec.slot, source = spec.source, positions = positions }
    end
    local function restore_record(u)
      local record = mod.cape_records[u]
      if not record then return true end
      if not record.active then
        mod.cape_blocked[u] = record
        return true
      end
      if alive(u) then
        local hex, why = bind_source(u, record, record.source)
        if not hex then return nil, why end
      end
      record.active = false
      mod.cape_blocked[u] = record
      return true
    end
    N.Unit.restore_private_cape = function(u)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if rat_cape_owners[u] and rat_cape_owners[u] ~= mod then return nil, "cape belongs to another mod" end
      local ok, why = restore_record(u)
      if not ok then return nil, why end
      return true
    end
    N.Unit.paint_private_cape = function(u, alias, fields)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) or mod.owned[u] ~= nil then return nil, "Cape unit is unavailable" end
      local world_fn = engine("Unit", "world")
      if not world_fn then return nil, "Cape unit is unavailable" end
      local nw, okw, w = packed(world_fn, u)
      if not okw or nw < 2 or not known_world(w) then return nil, "Cape unit is unavailable" end
      local res_fn = engine("Unit", "resource_name")
      if not res_fn then return nil, "binding unavailable" end
      local nr, okr, res = packed(res_fn, u)
      local path = okr and nr >= 2 and to_hex(res)
      local spec = path and CAPE_TYPES[path]
      if not spec then return nil, "This cape geometry has no live-paint contract" end
      local declared = hex16(alias) and mod.palette_aliases[alias]
      if not declared or not resource("material", alias) or alias == spec.source then
        return nil, "Private cape material is unavailable"
      end
      if type(fields) ~= "table" then return nil, "Invalid cape texture tuple" end
      local wanted = {}
      for field, value in pairs(fields) do
        if not CAPE_FIELD[field] or not declared[field] then return nil, "Undeclared cape texture slot" end
        local created = type(value) == "string" and mod.textures[value]
        local created_ok = created and created.mod == mod and not created.released and created.desc
        if not resource("texture", value) and not created_ok then return nil, "Cape texture is not loaded" end
        wanted[field] = value
      end
      for i = 1, #CAPE_FIELDS do
        if not wanted[CAPE_FIELDS[i]] then return nil, "Incomplete cape texture tuple" end
      end
      local record = mod.cape_records[u]
      if not record then
        local ok, result = pcall(snapshot, u, spec)
        if not ok then return nil, tostring(result) end
        record = result
        mod.cape_records[u] = record
      end
      local function transaction()
        if record.active then
          local hex, why = bind_source(u, record, record.source)
          if not hex then error(why, 0) end
          record.active = false
        end
        record.active = true
        local hex, why = bind_source(u, record, alias)
        if not hex then error(why, 0) end
        local mesh_count = engine("Unit", "num_meshes")
        local mesh_fn = engine("Unit", "mesh")
        local mat_count = engine("Mesh", "num_materials")
        local mat_fn = engine("Mesh", "material")
        local id_fn = engine("Material", "id64")
        local set_tex = engine("Material", "set_texture")
        local set_res = engine("Material", "set_resource")
        local reinit = engine("Material", "reinitialize_shader")
        local refresh = engine("Mesh", "refresh_instance_hash")
        local function material_at(pos)
          local nc, okc, count = packed(mesh_count, u)
          if not okc or pos[1] > count then error("cape mesh count changed", 0) end
          local nm, okm, mesh = packed(mesh_fn, u, pos[1])
          if not okm or mesh == nil then error("cape mesh count changed", 0) end
          local nj, okj, nmat = packed(mat_count, mesh)
          if not okj or pos[2] > nmat then error("cape slot count changed", 0) end
          local na, oka, mat = packed(mat_fn, mesh, pos[2])
          if not oka or mat == nil then error("cape slot count changed", 0) end
          local ni, oki, id = packed(id_fn, mat)
          if not oki or to_hex(id) ~= alias then error("private cape binding changed", 0) end
          return mat
        end
        for p = 1, #record.positions do
          local mat = material_at(record.positions[p])
          for f = 1, #CAPE_FIELDS do
            local field = CAPE_FIELDS[f]
            local created = mod.textures[wanted[field]]
            local desc = created and created.mod == mod and not created.released and created.desc
            local n, ok, err
            if desc then
              if not set_res then error("binding unavailable", 0) end
              n, ok, err = packed(set_res, mat, field, desc)
            else
              if not set_tex then error("binding unavailable", 0) end
              local tex = id64(wanted[field])
              if not tex then error("Cape texture is not loaded", 0) end
              n, ok, err = packed(set_tex, mat, field, tex)
            end
            if not ok then error(err, 0) end
            if n ~= 1 then error("unexpected private cape setter return", 0) end
          end
        end
        for p = 1, #record.positions do
          if not reinit then error("binding unavailable", 0) end
          local n, ok, err = packed(reinit, material_at(record.positions[p]))
          if not ok then error(err, 0) end
          if n ~= 1 then error("unexpected private cape setter return", 0) end
        end
        for p = 1, #record.positions do
          if not refresh then error("binding unavailable", 0) end
          local pos = record.positions[p]
          local nc, okc, count = packed(mesh_count, u)
          if not okc or pos[1] > count then error("cape mesh count changed", 0) end
          local nm, okm, mesh = packed(mesh_fn, u, pos[1])
          if not okm or mesh == nil then error("cape mesh count changed", 0) end
          local n, ok, value = packed(refresh, mesh)
          if not ok then error(value, 0) end
          if n ~= 2 or kind_of(value) ~= "MeshObject" then error("unexpected mesh refresh return", 0) end
        end
      end
      local ok, why = pcall(transaction)
      mod.cape_blocked[u] = record
      if record.active then rat_cape_owners[u] = mod else rat_cape_owners[u] = nil end
      if mod.rebound then mod.rebound[u] = nil end
      if not ok then
        local reset, problem = restore_record(u)
        return nil, tostring(why) .. (not reset and "; restore failed: " .. tostring(problem) or "")
      end
      return true
    end
  end

  local function install_texture()
    local function b64(bytes)
      local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
      local out, n = {}, #bytes
      for i = 1, n, 3 do
        local a, b, c = string.byte(bytes, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local d1, d2 = math.floor(v / 262144), math.floor(v / 4096) % 64
        local d3, d4 = math.floor(v / 64) % 64, v % 64
        local function ch(d) return string.sub(alphabet, d + 1, d + 1) end
        out[#out + 1] = ch(d1) .. ch(d2) .. (b and ch(d3) or "=") .. (c and ch(d4) or "=")
      end
      return table.concat(out)
    end
    local function renderer(name)
      local S = rawget(_G, "stingray")
      local box = type(S) == "table" and S.Renderer
      local fn = type(box) == "table" and box[name]
      if type(fn) ~= "function" then return nil end
      return fn
    end
    N.Texture.collect = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local destroy = renderer("destroy_resource")
      local now, freed = frame(), 0
      for name, t in pairs(mod.textures) do
        if t.released and t.refs <= 0 and now >= t.released + TEXTURE_DELAY and now > t.frame then
          if destroy then packed(destroy, t.desc) end
          mod.textures[name] = nil
          freed = freed + 1
        end
      end
      return freed
    end
    N.Texture.create = function(name, width, height, bytes)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not hex16(name) then return nil, "name is not 16 hex characters" end
      local create = renderer("create_resource")
      local update = renderer("update_texture_base64")
      local set_res = engine("Material", "set_resource")
      if not create or not update or not set_res then return nil, "binding unavailable" end
      local pending = mod.textures[name]
      if pending and pending.mod == mod and pending.released and not pending.initialized then
        N.Texture.collect()
        pending = mod.textures[name]
        if pending then return nil, "failed texture upload is awaiting retirement" end
      end
      if pending and pending.mod == mod and pending.released then pending.released = nil return true end
      if pending then return nil, "texture already exists" end
      if not whole(width, 1, 64) or not whole(height, 1, 64) then return nil, "size out of range" end
      if type(bytes) ~= "string" or #bytes ~= width * height * 8 or #bytes > TEXTURE_BYTES then
        return nil, "bytes do not match an RGBA16F image of this size"
      end
      local can = engine("Application", "can_get")
      local existing = id64(name)
      if can and existing then
        local n, ok, yes = packed(can, "texture", existing)
        if ok and n >= 2 and yes == true then return nil, "a game texture has this name" end
      end
      local live = 0
      for _, t in pairs(mod.textures) do
        if t.mod == mod and not t.released then live = live + 1 end
      end
      if live >= TEXTURE_LIMIT then return nil, "too many textures" end
      N.Texture.collect()
      local n, ok, desc = packed(create, "texture", "R16G16B16A16F", width, height)
      if not ok or n ~= 2 or type(desc) ~= "userdata" then
        return nil, ok and "unobserved return shape" or desc
      end
      local t = { desc = desc, mod = mod, frame = frame(), refs = 0 }
      mod.textures[name] = t
      local nu, oku, err = packed(update, desc, b64(bytes), #bytes)
      if not oku or nu ~= 1 then
        t.released = frame()
        return nil, oku and "unobserved return shape" or err
      end
      t.initialized = true
      return true
    end
    N.Texture.release = function(name)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local t = type(name) == "string" and mod.textures[name]
      if not t or t.mod ~= mod then return nil, "not a texture of this mod" end
      t.released = t.released or frame()
      return true
    end
    N.Texture.stats = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local live, pending, bound_n = 0, 0, 0
      for _, t in pairs(mod.textures) do
        if t.mod == mod then
          if t.released then pending = pending + 1 else live = live + 1 end
          if t.refs > 0 then bound_n = bound_n + 1 end
        end
      end
      return { live = live, pending = pending, bound = bound_n }
    end
  end

  local function install_world()
    N.World.spawn_unit = function(w, unit_resource, position, rotation)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      local res = resource("unit", unit_resource)
      if not res then return nil, "unit resource is not loaded" end
      if position ~= nil and kind_of(position) ~= "Vector3" then return nil, "position is not a Vector3" end
      if rotation ~= nil and kind_of(rotation) ~= "Quaternion" then return nil, "rotation is not a Quaternion" end
      if rotation ~= nil and position == nil then return nil, "rotation without position" end
      local fn = engine("World", "spawn_unit")
      if not fn then return nil, "missing" end
      local n, ok, u
      if rotation ~= nil then n, ok, u = packed(fn, w, res, position, rotation)
      elseif position ~= nil then n, ok, u = packed(fn, w, res, position)
      else n, ok, u = packed(fn, w, res) end
      if not ok then return nil, u end
      if u ~= nil then mod.owned[u] = w mod.spawned_at[u] = frame() end
      return u
    end
    N.World.destroy_unit = function(w, u)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      if not alive(u) then return nil, "not a live unit" end
      if mod.owned[u] == nil then return nil, "unit is not owned by this mod" end
      local world_fn = engine("Unit", "world")
      if not world_fn then return nil, "missing" end
      local n, ok, where = packed(world_fn, u)
      if not ok or where ~= w then return nil, "unit is in another world" end
      local fn = engine("World", "destroy_unit")
      if not fn then return nil, "missing" end
      local nd, okd, err = packed(fn, w, u)
      if not okd then return nil, err end
      mod.owned[u] = nil
      return true
    end
    N.World.link_unit = function(w, child, child_node, parent, parent_node)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      if not alive(child) or not alive(parent) then return nil, "not a live unit" end
      if mod.owned[child] == nil then return nil, "child is not owned by this mod" end
      if child == parent then return nil, "unit linked to itself" end
      local world_fn = engine("Unit", "world")
      if not world_fn then return nil, "missing" end
      local nc, okc, cw = packed(world_fn, child)
      local np, okp, pw = packed(world_fn, parent)
      if not okc or not okp or cw ~= w or pw ~= w then return nil, "units are not in this world" end
      if not node_ok(child, child_node) or not node_ok(parent, parent_node) then return nil, "no such node" end
      local fn = engine("World", "link_unit")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, w, child, child_node, parent, parent_node)
      if not ok then return nil, err end
      return true
    end
    N.World.unlink_unit = function(w, child)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      if not alive(child) then return nil, "not a live unit" end
      if mod.owned[child] == nil then return nil, "child is not owned by this mod" end
      local world_fn = engine("Unit", "world")
      if not world_fn then return nil, "missing" end
      local n, ok, where = packed(world_fn, child)
      if not ok or where ~= w then return nil, "unit is in another world" end
      local fn = engine("World", "unlink_unit")
      if not fn then return nil, "missing" end
      local nu, oku, err = packed(fn, w, child)
      if not oku then return nil, err end
      return true
    end
  end

  local function install_steam()
    local function steam_id(s)
      return type(s) == "string" and #s == 16 and string.match(s, "^%x+$") ~= nil
    end
    local function lobby_handle(h)
      return type(h) == "userdata" and tostring(h) == "[SteamLobby]"
    end
    N.Steam.user_id = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local fn = engine("Steam", "user_id")
      if not fn then return nil, "binding unavailable" end
      local n, ok, id = packed(fn)
      if not ok or n ~= 2 or not steam_id(id) then return nil, "unobserved return shape" end
      return id
    end
    N.Friends.playing_game = function(id)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not steam_id(id) then return nil, "invalid Steam id" end
      local fn = engine("Friends", "playing_game")
      if not fn then return nil, "no lobby" end
      local n, ok, t = packed(fn, id)
      if not ok or n ~= 2 or type(t) ~= "table" then return nil, "no lobby" end
      if t.app_id ~= 553850 or not steam_id(t.lobby) or string.lower(t.lobby) == "0000000000000000" then return nil, "no lobby" end
      if mod.lobby_current ~= t.lobby then mod.lobby_handles, mod.lobby_current = {}, t.lobby end
      mod.lobby_reported = t.lobby
      return { app_id = t.app_id, lobby = t.lobby }
    end
    N.Network.join_steam_lobby = function(lobby)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not steam_id(lobby) or lobby ~= mod.lobby_reported or lobby ~= mod.lobby_current then
        return nil, "not the reported lobby"
      end
      if mod.lobby_handles[lobby] then return mod.lobby_handles[lobby] end
      local fn = engine("Network", "join_steam_lobby")
      if not fn then return nil, "missing" end
      local n, ok, h = packed(fn, lobby)
      if not ok or n ~= 2 or not lobby_handle(h) then return nil, "unobserved return shape" end
      mod.lobby_handles[lobby] = h
      return h
    end
    N.SteamLobby.state = function(h)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not lobby_handle(h) then return nil, "invalid lobby handle" end
      local fn = engine("SteamLobby", "state")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, h)
      if not ok or n ~= 2 or type(v) ~= "number" then return nil, "unobserved return shape" end
      return v
    end
    N.SteamLobby.members = function(h)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not lobby_handle(h) then return nil, "invalid lobby handle" end
      local fn = engine("SteamLobby", "members")
      if not fn then return nil, "missing" end
      local n, ok, list = packed(fn, h)
      if not ok or n ~= 2 or type(list) ~= "table" then return nil, "unobserved return shape" end
      local out = {}
      for i = 1, math.min(#list, 64) do
        if steam_id(list[i]) then out[#out + 1] = string.lower(list[i]) end
      end
      return out
    end
    N.SteamLobby.member_data = function(h, id, key)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not lobby_handle(h) then return nil, "invalid lobby handle" end
      if not steam_id(id) then return nil, "invalid member id" end
      if mod.lobby_key == nil or key ~= mod.lobby_key then return nil, "not this mod's lobby key" end
      local fn = engine("SteamLobby", "member_data")
      if not fn then return nil, "missing" end
      local n, ok, v = packed(fn, h, id, key)
      if not ok or n ~= 2 or type(v) ~= "string" then return nil, "unobserved return shape" end
      return v
    end
    N.SteamLobby.set_member_data = function(h, key, value)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not lobby_handle(h) then return nil, "invalid lobby handle" end
      if mod.lobby_key == nil or key ~= mod.lobby_key then return nil, "not this mod's lobby key" end
      if type(value) ~= "string" or #value > 1024 or string.find(value, "%z") then
        return nil, "value is not a short string"
      end
      local fn = engine("SteamLobby", "set_member_data")
      if not fn then return nil, "missing" end
      local n, ok, err = packed(fn, h, key, value)
      if not ok then return nil, err end
      return true
    end
  end

  local function install_session()
    local checked = false
    local function peer(v)
      return type(v) == "string" and #v == 16 and string.match(v, "^[0-9a-f]+$") ~= nil
    end
    local function finite(v)
      return type(v) == "number" and v == v and v > -math.huge and v < math.huge
    end
    local function need(ns, name)
      return engine(ns, name) ~= nil
    end
    local function read_session()
      local need_net = { "game_session", "peer_id", "object_info" }
      local need_gs = { "in_session", "peers", "objects_owned_by", "game_object_exists", "game_object_is_type", "game_object_owner", "game_object_field" }
      for i = 1, #need_net do if not need("Network", need_net[i]) then return nil, "Native character observation unavailable" end end
      for i = 1, #need_gs do if not need("GameSession", need_gs[i]) then return nil, "Native character observation unavailable" end end
      local gs_fn = engine("Network", "game_session")
      local n, ok, gs = packed(gs_fn)
      if not ok or n ~= 2 or kind_of(gs) ~= "GameSession" then return nil, "Waiting for the game session" end
      local in_fn = engine("GameSession", "in_session")
      local ni, oki, inside = packed(in_fn, gs)
      if not oki or inside ~= true then return nil, "Waiting for the game session" end
      local me_fn = engine("Network", "peer_id")
      local nm, okm, me = packed(me_fn)
      if not okm or not peer(me) then return nil, "Waiting for native peer identity" end
      local peers_fn = engine("GameSession", "peers")
      local np, okp, members = packed(peers_fn, gs)
      if not okp or type(members) ~= "table" or #members < 1 or #members > 8 then return nil, "Native membership unavailable" end
      local seen, present, count = {}, false, 0
      for k, p in pairs(members) do
        if not whole(k, 1, #members) or not peer(p) or seen[p] then return nil, "Invalid native membership" end
        seen[p] = true
        count = count + 1
        if p == me then present = true end
      end
      if count ~= #members or not present then return nil, "Native membership is changing" end
      if not checked then
        local info_fn = engine("Network", "object_info")
        local typ = id64("5d9752f900000000")
        if not typ then return nil, "Native character schema is unsupported" end
        local ns, oks, schema = packed(info_fn, typ)
        local field = oks and type(schema) == "table" and type(schema.fields) == "table" and schema.fields[23]
        if not field or #schema.fields ~= 72 or field.id ~= "8bbeb160" or field.type ~= 3 then
          return nil, "Native character schema is unsupported"
        end
        checked = true
      end
      local owned_fn = engine("GameSession", "objects_owned_by")
      local no, oko, ids = packed(owned_fn, gs, me)
      if not oko or type(ids) ~= "table" or #ids > 8192 then return nil, "Native character list unavailable" end
      local typ = id64("5d9752f900000000")
      local exists = engine("GameSession", "game_object_exists")
      local is_type = engine("GameSession", "game_object_is_type")
      local owner = engine("GameSession", "game_object_owner")
      local field_fn = engine("GameSession", "game_object_field")
      local objects, unique = {}, {}
      for k, id in pairs(ids) do
        if not whole(k, 1, #ids) or not whole(id, 0, 2147483647) or unique[id] then
          return nil, "Invalid native object list"
        end
        unique[id] = true
        local ne, oke, ex = packed(exists, gs, id)
        local nt, okt, ty = packed(is_type, gs, id, typ)
        local nw, okw, who = packed(owner, gs, id)
        if oke and ex == true and okt and ty == true and okw and who == me then
          local nf, okf, pos = packed(field_fn, gs, id, "position")
          if not okf or kind_of(pos) ~= "Vector3" then return nil, "Native position unavailable" end
          local x, y, z = vec_xyz(pos)
          if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or not finite(x) or not finite(y) or not finite(z) then
            return nil, "Invalid native position"
          end
          objects[#objects + 1] = { id = id, position = { x, y, z } }
          if #objects > 16 then return nil, "Too many native character objects" end
        end
      end
      return { peer = me, members = #members, objects = objects }
    end
    N.CharacterSession = {
      snapshot = function()
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        local ok, result, why = pcall(read_session)
        if not ok then return nil, "Native character observation failed: " .. tostring(result) end
        return result, why
      end,
    }
  end

  local function install_app()
    N.Application.can_get = function(kind, id)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if type(kind) ~= "string" then return nil, "type is not a string" end
      local created = kind == "texture" and type(id) == "string" and mod.textures[id]
      if created then return created.mod == mod and not created.released end
      return resource(kind, id) ~= nil
    end
    local names = { "main_world", "build", "build_identifier", "platform", "time_since_launch", "resolution", "argv" }
    for i = 1, #names do
      local name = names[i]
      N.Application[name] = function()
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        local fn = engine("Application", name)
        if not fn then return nil, "missing" end
        local n, ok, a, b, c = packed(fn)
        if not ok then return nil, a end
        return a, b, c
      end
    end
    N.Keyboard.pressed = function(name)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if type(name) ~= "string" or name == "" or #name > 40 then return nil, "invalid button name" end
      local index_fn = engine("Keyboard", "button_index")
      local pressed = engine("Keyboard", "pressed")
      local count_fn = engine("Keyboard", "num_buttons")
      if not index_fn or not pressed or not count_fn then return nil, "keyboard binding unavailable" end
      local ni, oki, index = packed(index_fn, name)
      local nc, okc, count = packed(count_fn)
      if not oki or not okc or not whole(index, 0, (nc >= 2 and type(count) == "number" and count - 1) or -1) then
        return nil, "unknown button"
      end
      local n, ok, down = packed(pressed, index)
      if not ok then return nil, down end
      return down
    end
  end

  local function install_release()
    mod.rat_release = function()
      local S = rawget(_G, "stingray")
      if type(S) ~= "table" then return end
      for u, record in pairs(mod.cape_records) do
        if record.active and alive(u) and type(S.Unit) == "table" and type(S.Unit.set_material) == "function" then
          local slot = id32(record.slot)
          local mat = id64(record.source)
          if slot and mat then pcall(S.Unit.set_material, u, slot, mat) end
          record.active = false
        end
      end
      if type(S.Unit) == "table" and type(S.Unit.set_local_position) == "function" and type(S.Vector3) ~= "nil" then
        for u, record in pairs(mod.cape_shift) do
          if alive(u) then
            for bone, base in pairs(record) do
              local has = engine("Unit", "has_node")
              local node_fn = engine("Unit", "node")
              if has and node_fn then
                local nh, okh, yes = packed(has, u, bone)
                if okh and yes == true then
                  local nn, okn, node = packed(node_fn, u, bone)
                  local point = vec3(base[1], base[2], base[3])
                  if okn and node ~= nil and point then pcall(S.Unit.set_local_position, u, node, point) end
                end
              end
            end
          end
        end
      end
      mod.cape_shift = {}
      if type(S.Unit) == "table" and type(S.Mesh) == "table" then
        for u, list in pairs(mod.rebound or {}) do
          if alive(u) then
            local meshes = engine("Unit", "num_meshes")
            local mesh_fn = engine("Unit", "mesh")
            local mats = engine("Mesh", "num_materials")
            local slot_fn = engine("Mesh", "material_slot_id")
            local set_fn = engine("Unit", "set_material")
            if meshes and mesh_fn and mats and slot_fn and set_fn then
              for key, previous in pairs(list) do
                local si, sj = string.match(key, "^(%d+):(%d+)$")
                local i, j = tonumber(si), tonumber(sj)
                if i and j and hex16(previous) then
                  local nc, okc, count = packed(meshes, u)
                  if okc and type(count) == "number" and i <= count then
                    local nm, okm, mesh = packed(mesh_fn, u, i)
                    local nj, okj, nmat = 0, false, nil
                    if okm and mesh then nj, okj, nmat = packed(mats, mesh) end
                    if okm and mesh and okj and type(nmat) == "number" and j <= nmat then
                      local ns, oks, slot = packed(slot_fn, mesh, j)
                      local mat = id64(previous)
                      if oks and slot and mat then pcall(set_fn, u, slot, mat) end
                    end
                  end
                end
              end
            end
          end
        end
      end
      mod.rebound = {}
      if type(S.Renderer) == "table" and type(S.Renderer.destroy_resource) == "function" then
        for _, t in pairs(mod.textures) do
          if t.mod == mod and t.desc ~= nil then pcall(S.Renderer.destroy_resource, t.desc) end
        end
      end
      mod.textures = {}
    end
  end

  install_units()
  install_mesh()
  install_material()
  install_cape()
  install_texture()
  install_world()
  install_steam()
  install_session()
  install_app()
  install_release()
  local namespaces = {
    "Unit", "Mesh", "Material", "World", "Application", "Keyboard", "Mouse", "Window", "Gui",
    "Steam", "Friends", "Network", "SteamLobby", "Texture",
  }
  for i = 1, #namespaces do
    if type(N[namespaces[i]]) == "table" then setmetatable(N[namespaces[i]], nil) end
  end
end

local function install_hd2rt()
  if type(package) ~= "table" then return end
  if type(package.loaded) == "table" and type(package.loaded.hd2rt) == "table" then return end
  local mods, order, frame_n = {}, {}, 0
  local dir = data_dir()
  local public = {
    version = "0.1.1", api = 1, loader = "ordnance", runtime = "ordnance-loader-1",
  }
  local function guard(mod, ns, key)
    return function(...)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local S = rawget(_G, "stingray")
      local obj = type(S) == "table" and S[ns]
      local fn = type(obj) == "table" and obj[key]
      if type(fn) ~= "function" then return nil, "missing" end
      local packed = { pcall(fn, ...) }
      if not packed[1] then return nil, packed[2] end
      return unpack(packed, 2, #packed)
    end
  end
  local function alive(u)
    local S = rawget(_G, "stingray")
    local fn = type(S) == "table" and S.Unit and S.Unit.alive
    if type(fn) ~= "function" then return true end
    local ok, v = pcall(fn, u)
    return ok and v == true
  end
  local function bad_kind(u)
    local S = rawget(_G, "stingray")
    local fn = type(S) == "table" and S.Unit and S.Unit.debug_name
    if type(fn) ~= "function" then return false end
    local ok, name = pcall(fn, u)
    return ok and type(name) == "string" and string.find(string.lower(name), "46cab355bd8d4d37", 1, true) ~= nil
  end
  local function engine_for(mod)
    local names = { "Unit", "Mesh", "Material", "World", "Application", "Keyboard", "Mouse", "Window", "Gui", "Steam", "Friends", "Network", "SteamLobby", "Texture" }
    local N = {}
    for i = 1, #names do
      local ns = names[i]
      N[ns] = setmetatable({}, { __index = function(_, key) return guard(mod, ns, key) end })
    end
    local S0 = rawget(_G, "stingray") or {}
    N.Vector2, N.Quaternion, N.Matrix4x4, N.Color = S0.Vector2, S0.Quaternion, S0.Matrix4x4, S0.Color
    local raw_v3 = S0.Vector3
    local function vector_field(obj, name)
      if type(obj) == "table" then return obj[name] end
      if type(obj) ~= "function" then return nil end
      local ok, value = pcall(function() return obj[name] end)
      if ok then return value end
    end
    local function v3_elements(v)
      local S = rawget(_G, "stingray")
      local V = type(S) == "table" and S.Vector3 or raw_v3
      if V == nil then V = raw_v3 end
      local to = vector_field(V, "to_elements")
      if type(to) == "function" then
        local ok, x, y, z = pcall(to, v)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
        if ok and type(x) == "table" and type(x.x) == "number" and type(x.y) == "number" and type(x.z) == "number" then
          return x.x, x.y, x.z
        end
      end
      local xfn, yfn, zfn = vector_field(V, "x"), vector_field(V, "y"), vector_field(V, "z")
      if type(xfn) == "function" and type(yfn) == "function" and type(zfn) == "function" then
        local okx, x = pcall(xfn, v)
        local oky, y = pcall(yfn, v)
        local okz, z = pcall(zfn, v)
        if okx and oky and okz and type(x) == "number" and type(y) == "number" and type(z) == "number" then
          return x, y, z
        end
      end
    end
    N.Vector3 = setmetatable({
      x = function(v) local x = v3_elements(v) return x end,
      y = function(v) local _, y = v3_elements(v) return y end,
      z = function(v) local _, _, z = v3_elements(v) return z end,
      length = function(v)
        local x, y, z = v3_elements(v)
        if type(x) ~= "number" then return nil end
        return math.sqrt(x * x + y * y + z * z)
      end,
    }, {
      __index = raw_v3,
      __call = function(_, ...)
        if type(raw_v3) ~= "function" and type(raw_v3) ~= "table" then return nil, "missing" end
        local packed = { pcall(raw_v3, ...) }
        if not packed[1] then return nil, packed[2] end
        return unpack(packed, 2, #packed)
      end,
    })
    local raw_ids = S0.IdString64
    N.IdString64 = setmetatable({
      from_hex = function(text)
        if type(text) ~= "string" or not string.match(text, "^%x+$") or #text ~= 16 then
          return nil, "not 16 hex characters"
        end
        local S = rawget(_G, "stingray")
        local fn = type(S) == "table" and type(S.IdString64) == "table" and S.IdString64.from_hex
        if type(fn) ~= "function" then return nil, "missing" end
        local ok, id = pcall(fn, text)
        if not ok then return nil, id end
        return id
      end,
      to_hex = function(value)
        if type(value) ~= "userdata" then return nil, "not an engine id" end
        local S = rawget(_G, "stingray")
        local fn = type(S) == "table" and type(S.IdString64) == "table" and S.IdString64.to_hex
        if type(fn) ~= "function" then return nil, "missing" end
        local ok, hex = pcall(fn, value)
        if not ok then return nil, hex end
        return hex
      end,
    }, {
      __index = raw_ids,
      __call = function(_, ...)
        if type(raw_ids) ~= "function" and type(raw_ids) ~= "table" then return nil, "missing" end
        local packed = { pcall(raw_ids, ...) }
        if not packed[1] then return nil, packed[2] end
        return unpack(packed, 2, #packed)
      end,
    })
    local posed = { "world_position", "world_rotation", "world_pose", "local_position", "local_rotation", "local_scale", "local_pose" }
    for i = 1, #posed do
      local name = posed[i]
      N.Unit[name] = function(u, node)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        if bad_kind(u) then return nil, "runtime-built unit" end
        return guard(mod, "Unit", name)(u, node == nil and 1 or node)
      end
    end
    local function owned(u)
      return mod.owned[u] ~= nil
    end
    for _, name in ipairs({ "set_local_position", "set_local_rotation", "set_local_scale" }) do
      N.Unit[name] = function(u, node, value)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        if not owned(u) then return nil, "unit is not owned by this mod" end
        return guard(mod, "Unit", name)(u, node, value)
      end
    end
    N.Unit.set_unit_visibility = function(u, on, ...)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      local a, b = guard(mod, "Unit", "set_unit_visibility")(u, on, ...)
      if b == nil then
        if on == false then mod.hidden[u] = true else mod.hidden[u] = nil end
      end
      return a, b
    end
    N.Unit.bones = function(u)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not alive(u) then return nil, "not a live unit" end
      local allowed = false
      local S = rawget(_G, "stingray")
      if type(mod.bones) == "table" and type(S) == "table" and type(S.Unit) == "table" and type(S.Unit.resource_name) == "function" then
        local ok, res = pcall(S.Unit.resource_name, u)
        local hex
        if ok and type(res) == "userdata" and type(S.IdString64) == "table" and type(S.IdString64.to_hex) == "function" then
          local okh, h = pcall(S.IdString64.to_hex, res)
          if okh and type(h) == "string" then hex = string.lower(h) end
        end
        if hex then
          for i = 1, #mod.bones do
            if string.lower(mod.bones[i]) == hex then allowed = true break end
          end
        end
      end
      if not allowed then return nil, "unit resource not declared for bone names" end
      return guard(mod, "Unit", "bones")(u)
    end
    for _, name in ipairs({ "has_node", "node", "mesh", "set_material_at", "set_mesh_visibility" }) do
      N.Unit[name] = function(u, ...)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if not alive(u) then return nil, "not a live unit" end
        return guard(mod, "Unit", name)(u, ...)
      end
    end
    local function material_method(name)
      return function(mat, ...)
        if mod.phase ~= "active" then return nil, "mod is disabled" end
        if type(mat) ~= "userdata" then return nil, "material handle is stale or unknown" end
        return guard(mod, "Material", name)(mat, ...)
      end
    end
    for _, name in ipairs({ "id64", "set_scalar", "set_vector2", "set_vector3", "set_vector4", "set_uint_vector", "set_texture", "reinitialize_shader" }) do
      N.Material[name] = material_method(name)
    end
    local function resource_id(id)
      if type(id) == "userdata" then return id end
      if type(id) ~= "string" or not string.match(id, "^%x+$") or #id ~= 16 then return nil end
      local S = rawget(_G, "stingray")
      local from = type(S) == "table" and type(S.IdString64) == "table" and S.IdString64.from_hex
      if type(from) ~= "function" then return nil end
      local ok, converted = pcall(from, string.lower(id))
      if not ok then return nil end
      return converted
    end
    local function as_list(list)
      if type(list) ~= "table" then return nil end
      local n = #list
      if n == 0 and list[1] ~= nil then
        local i = 1
        while list[i] ~= nil and i < 100000 do i = i + 1 end
        n = i - 1
      end
      local out = {}
      for i = 1, n do out[i] = list[i] end
      return out
    end
    local function named_units(w, hex)
      local now = os.clock()
      if mod.name_world ~= w or not mod.name_index or not mod.name_at or now - mod.name_at >= 0.25 then
        local map = {}
        local S = rawget(_G, "stingray")
        local dn = type(S) == "table" and type(S.Unit) == "table" and S.Unit.debug_name
        local units = as_list(guard(mod, "World", "units")(w))
        if type(dn) == "function" and units then
          for i = 1, #units do
            local u = units[i]
            local ok, name = pcall(dn, u)
            if ok and type(name) == "string" then
              local id = string.match(name, "#ID%[(%x+)%]")
              if id then
                id = string.lower(id)
                local bucket = map[id]
                if bucket == nil then bucket = {} map[id] = bucket end
                bucket[#bucket + 1] = u
              end
            end
          end
        end
        mod.name_world, mod.name_index, mod.name_at = w, map, now
      end
      local found = mod.name_index and mod.name_index[string.lower(hex)]
      local out = {}
      if type(found) == "table" then
        for i = 1, #found do out[i] = found[i] end
      end
      return out
    end
    N.World.spawn_unit = function(w, res, pos, rot)
      if type(res) == "string" then
        local id = resource_id(res)
        if id == nil then return nil, "not a resource id" end
        res = id
      end
      local u, err = guard(mod, "World", "spawn_unit")(w, res, pos, rot)
      if u ~= nil and err == nil then mod.owned[u] = w end
      return u, err
    end
    N.World.destroy_unit = function(w, u)
      local a, b = guard(mod, "World", "destroy_unit")(w, u)
      if b == nil then mod.owned[u] = nil end
      return a, b
    end
    local function known_world(w)
      local list = N.Application.worlds()
      if type(list) ~= "table" then return true end
      for _, v in pairs(list) do if v == w then return true end end
      return false
    end
    N.World.units = function(w)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      local list, err = guard(mod, "World", "units")(w)
      local out = as_list(list)
      if out == nil then return nil, err or "missing" end
      return out
    end
    N.World.units_by_resource = function(w, id)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      local res = resource_id(id)
      if res == nil then return nil, "not a resource id" end
      local list, err = guard(mod, "World", "units_by_resource")(w, res)
      local out = as_list(list)
      if out == nil then return nil, err or "missing" end
      if #out == 0 and type(id) == "string" then out = named_units(w, id) end
      return out
    end
    N.World.num_units = function(w)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      return guard(mod, "World", "num_units")(w)
    end
    N.Application.worlds = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if mod.worlds_frame == frame_n and type(mod.worlds) == "table" then return mod.worlds end
      local list, err = guard(mod, "Application", "worlds")()
      local out = as_list(list)
      mod.worlds_frame = frame_n
      mod.worlds = out or list
      if out == nil then return nil, err or "missing" end
      return out
    end
    N.Window.ui_state = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local S = rawget(_G, "stingray")
      local W = type(S) == "table" and S.Window or nil
      if type(W) ~= "table" or type(W.get_main_window) ~= "function" then
        return nil, "window binding unavailable"
      end
      local ok, window = pcall(W.get_main_window)
      if not ok or window == nil then return nil, "invalid main window" end
      local out = {}
      for _, name in ipairs({ "has_focus", "show_cursor", "mouse_focus" }) do
        local fn = W[name]
        if type(fn) ~= "function" then return nil, "window binding unavailable" end
        local okv, value = pcall(fn, window)
        if not okv or type(value) ~= "boolean" then return nil, "window binding unavailable" end
        out[name] = value
      end
      if out.has_focus == true and not mod.told_window then
        mod.told_window = true
        say(string.format("window focus=%s cursor=%s mouse=%s", tostring(out.has_focus), tostring(out.show_cursor), tostring(out.mouse_focus)))
      end
      -- Gameplay hides the cursor and often reports the mouse as unfocused. The
      -- world picker drops typed text unless mouse_focus is true. A visible
      -- cursor keeps the engine's flag so the game menu still reads as open.
      if out.has_focus == true and out.show_cursor == false and out.mouse_focus == false then
        out.mouse_focus = true
      end
      return out
    end
    N.Keyboard.pressed = function(name)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if type(name) ~= "string" or name == "" or #name > 40 then return nil, "invalid button name" end
      local S = rawget(_G, "stingray")
      local K = type(S) == "table" and S.Keyboard or nil
      if type(K) ~= "table" or type(K.button_index) ~= "function" or type(K.pressed) ~= "function" then
        return nil, "keyboard binding unavailable"
      end
      local oki, index = pcall(K.button_index, name)
      if not oki or type(index) ~= "number" then return false end
      local okp, down = pcall(K.pressed, index)
      if not okp then return nil, down end
      return down == true
    end
    N.Application.quit = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local S = rawget(_G, "stingray")
      local fn = type(S) == "table" and S.Application and S.Application.quit
      if type(fn) ~= "function" then return nil, "missing" end
      pcall(fn)
      return true
    end
    -- The in-world picker freezes look by widening the mouse dead zone, and it
    -- only remembers the old zone when this call returns true. The engine
    -- itself returns nothing, so a bare forward left the camera stuck.
    local function whole(n, lo, hi)
      return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
    end
    local function finite(v, limit)
      return type(v) == "number" and v == v and math.abs(v) <= limit
    end
    local function axis_count()
      local n = guard(mod, "Mouse", "num_axes")()
      if not whole(n, 0, 64) then return nil end
      return n
    end
    local function button_count()
      local n = guard(mod, "Mouse", "num_buttons")()
      if not whole(n, 0, 512) then return nil end
      return n
    end
    local function zone_ok(mode, size)
      return (mode == 0 or mode == 1 or mode == 2) and finite(size, 1e9) and size >= 0
    end
    local function stingray_of()
      local S = rawget(_G, "stingray")
      if type(S) ~= "table" then return nil end
      return S
    end
    local function make_vec3(x, y, z)
      local S = stingray_of()
      local V = S and S.Vector3
      if type(V) ~= "function" and type(V) ~= "table" then return nil end
      local ok, v = pcall(V, x, y, z)
      if ok then return v end
    end
    local function make_vec2(x, y)
      local S = stingray_of()
      local V = S and S.Vector2
      if type(V) ~= "function" and type(V) ~= "table" then return nil end
      local ok, v = pcall(V, x, y)
      if ok then return v end
    end
    local function make_color(a, r, g, b)
      local S = stingray_of()
      local C = S and S.Color
      if type(C) ~= "function" and type(C) ~= "table" then return nil end
      local ok, c = pcall(C, a, r, g, b)
      if ok then return c end
    end
    local function pair_xy(v)
      if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
      if type(v.x) == "number" and type(v.y) == "number" then return v.x, v.y end
      local S = stingray_of()
      local to = S and ((S.Vector2 and S.Vector2.to_elements) or (S.Vector3 and S.Vector3.to_elements))
      if type(to) ~= "function" then return nil end
      local ok, x, y = pcall(to, v)
      if ok and type(x) == "number" and type(y) == "number" then return x, y end
    end
    local function rect_problem(x, y, z, w, h, r, g, b, a)
      if not finite(x, 32768) or not finite(y, 32768) or not finite(z, 10000)
        or not finite(w, 32768) or not finite(h, 32768) or w <= 0 or h <= 0 then
        return "invalid rectangle"
      end
      if not finite(r, 255) or r < 0 or not finite(g, 255) or g < 0
        or not finite(b, 255) or b < 0 or not finite(a, 255) or a < 0 then
        return "invalid color"
      end
    end
    local function gui_of(g)
      local d = mod.guis and mod.guis[g]
      if not d or not known_world(d.world) then return nil end
      return d
    end
    local FONT_MAT = {
      ["content/fonts/fallback"] = "content/fonts/runtime_font",
      ["content/fonts/fs_sinclair_medium_runtime"] = "content/fonts/runtime_font",
      ["9ad413a8fea59728"] = "content/fonts/runtime_font",
    }
    local function engine_font(font)
      if not string.match(font, "^%x+$") then return font end
      local S = stingray_of()
      local from = S and S.IdString64 and S.IdString64.from_hex
      if type(from) ~= "function" then return nil end
      local ok, id = pcall(from, font)
      if ok then return id end
    end
    local function font_problem(s, font, size)
      if type(s) ~= "string" or #s > 1024 or string.find(s, "%z") then return "invalid text" end
      if not FONT_MAT[font] then return "font not allowed" end
      if not finite(size, 512) or size <= 0 then return "invalid size" end
      if mod.font_ok and mod.font_ok[font] then return nil end
      local S = stingray_of()
      local can = S and S.Application and S.Application.can_get
      local id = engine_font(font)
      if type(can) ~= "function" or id == nil then return "font not resident" end
      local ok1, yes1 = pcall(can, "runtime_font", id)
      local ok2, yes2 = pcall(can, "material", FONT_MAT[font])
      if not (ok1 and yes1 == true and ok2 and yes2 == true) then return "font not resident" end
      mod.font_ok = mod.font_ok or {}
      mod.font_ok[font] = true
    end
    local function paint_rect(g, x, y, z, w, h, r, gr, b, a)
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.rect
      local p, s, c = make_vec3(x, y, z), make_vec2(w, h), make_color(a, r, gr, b)
      if type(fn) ~= "function" or not p or not s or not c then return nil, "missing" end
      local ok, id = pcall(fn, g, p, s, c)
      if not ok then return nil, id end
      return id
    end
    N.Mouse.num_axes = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = axis_count()
      if n == nil then return nil, "invalid device count" end
      return n
    end
    N.Mouse.num_buttons = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = button_count()
      if n == nil then return nil, "invalid device count" end
      return n
    end
    N.Mouse.axis = function(index)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = axis_count()
      if n == nil or not whole(index, 0, n - 1) then return nil, "invalid axis" end
      local v, err = guard(mod, "Mouse", "axis")(index)
      local x, y, z = v3_elements(v)
      if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil, err or "invalid axis coordinates"
      end
      return { x = x, y = y, z = z }
    end
    N.Mouse.button = function(index)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = button_count()
      if n == nil or not whole(index, 0, n - 1) then return nil, "invalid button" end
      local value, err = guard(mod, "Mouse", "button")(index)
      if value == true then value = 1 elseif value == false then value = 0 end
      if value ~= 0 and value ~= 1 then return nil, err or "unobserved button shape" end
      return value
    end
    N.Mouse.dead_zone = function(index)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = axis_count()
      if n == nil or not whole(index, 0, n - 1) then return nil, "invalid axis" end
      local mode, size = guard(mod, "Mouse", "dead_zone")(index)
      if not zone_ok(mode, size) then return nil, "unobserved dead zone shape" end
      return mode, size
    end
    N.Mouse.set_dead_zone = function(index, mode, size)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local n = axis_count()
      if n == nil or not whole(index, 0, n - 1) then return nil, "invalid axis" end
      if not zone_ok(mode, size) then return nil, "invalid dead zone" end
      if size >= 0.5 and size <= 10 then return nil, "size near 1 breaks the camera" end
      if mod.zones[index] == nil then
        local prev_mode, prev_size = guard(mod, "Mouse", "dead_zone")(index)
        if not zone_ok(prev_mode, prev_size) then return nil, "unobserved dead zone shape" end
        mod.zones[index] = { mode = prev_mode, size = prev_size }
      end
      local S = stingray_of()
      local fn = S and S.Mouse and S.Mouse.set_dead_zone
      if type(fn) ~= "function" then return nil, "missing" end
      local ok, err = pcall(fn, index, mode, size)
      if not ok then return nil, err end
      return true
    end
    N.Keyboard.keystrokes = function()
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local S = stingray_of()
      local live = S and S.Keyboard and S.Keyboard.keystrokes
      if type(live) ~= "function" then return nil, "keyboard binding unavailable" end
      -- The options menu swaps in an empty list while it is open. The world
      -- picker's search reads this list, so an empty stand-in falls through to
      -- the engine function captured before that swap.
      local packed = { pcall(live) }
      local events = packed[1] and packed[2] or nil
      if packed[1] and type(events) ~= "table" and type(packed[3]) == "table" then events = packed[3] end
      local raw = raw_input.keystrokes
      if (type(events) ~= "table" or #events == 0) and type(raw) == "function" and raw ~= live then
        local again = { pcall(raw) }
        local second = again[1] and again[2] or nil
        if again[1] and type(second) ~= "table" and type(again[3]) == "table" then second = again[3] end
        if type(second) == "table" and #second > 0 then events = second
        elseif again[1] and events == nil then events = second end
      end
      if type(events) == "string" or (type(events) == "number" and events == math.floor(events)) then events = { events } end
      if type(events) ~= "table" then
        if not mod.told_keys and events ~= nil then
          mod.told_keys = true
          say("keystrokes raw " .. type(events))
        end
        return {}
      end
      if #events > 128 then return nil, "text exceeds budget" end
      local out, bytes = {}, 0
      for i = 1, #events do
        local value = events[i]
        if type(value) == "number" and value == math.floor(value) then
          if value == 10 then value = 13 elseif value == 127 then value = 8 end
          if value >= 0 and value <= 255 then out[#out + 1] = value end
        elseif type(value) == "string" and #value > 0 and #value <= 1024 and bytes + #value <= 4096 then
          if not string.find(value, "[%z\1-\31\127]") then
            bytes = bytes + #value
            out[#out + 1] = value
          else
            local run, stop = "", false
            for p = 1, #value do
              local b = string.byte(value, p)
              if b < 32 or b == 127 then
                if run ~= "" then
                  if bytes + #run > 4096 then
                    stop = true
                    break
                  end
                  bytes = bytes + #run
                  out[#out + 1] = run
                  run = ""
                end
                if b == 10 or b == 13 then out[#out + 1] = 13
                elseif b == 8 or b == 127 then out[#out + 1] = 8
                else out[#out + 1] = b end
              else
                run = run .. string.char(b)
              end
            end
            if stop then break end
            if run ~= "" and bytes + #run <= 4096 then
              bytes = bytes + #run
              out[#out + 1] = run
            end
          end
        elseif type(value) == "string" and (bytes + #value > 4096 or #value > 1024) then
          break
        end
      end
      if not mod.told_keys and #out > 0 then
        mod.told_keys = true
        local parts = {}
        for n = 1, math.min(#out, 6) do
          local e = out[n]
          parts[n] = type(e) == "number" and ("n:" .. tostring(e)) or ("s:" .. tostring(#e))
        end
        say("keystrokes " .. table.concat(parts, " "))
      end
      return out
    end
    N.World.create_screen_gui = function(w)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not known_world(w) then return nil, "not a live world" end
      mod.guis = mod.guis or {}
      local count = 0
      for _ in pairs(mod.guis) do count = count + 1 end
      if count >= 6 then return nil, "GUI limit reached" end
      local S = stingray_of()
      local fn = S and S.World and S.World.create_screen_gui
      if type(fn) ~= "function" then return nil, "missing" end
      local ok, g = pcall(fn, w, "scale", 1, 1)
      if not ok or g == nil then return nil, (ok and "missing" or g) end
      mod.guis[g] = { world = w, count = 0, ids = {}, texts = {} }
      return g
    end
    N.World.destroy_gui = function(w, g)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d or d.world ~= w then return nil, "GUI is not owned in this live world" end
      local S = stingray_of()
      local fn = S and S.World and S.World.destroy_gui
      if type(fn) ~= "function" then return nil, "missing" end
      local ok, err = pcall(fn, w, g)
      if not ok then return nil, err end
      mod.guis[g] = nil
      return true
    end
    N.Gui.rect = function(g, x, y, z, w, h, r, gr, b, a)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
      if problem then return nil, problem end
      if d.count >= 12000 then return nil, "primitive limit reached" end
      local id, err = paint_rect(g, x, y, z, w, h, r, gr, b, a)
      if id == nil then return nil, err or "missing" end
      d.count = d.count + 1
      if type(id) == "number" then d.ids[id] = true end
      return id
    end
    N.Gui.rects = function(g, buf, n, ids)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      if type(buf) ~= "table" or not whole(n, 0, 4096) or #buf < n * 9 or (ids ~= nil and type(ids) ~= "table") then
        return nil, "invalid batch"
      end
      if d.count + n > 12000 then return nil, "primitive limit reached" end
      for i = 0, n - 1 do
        local o = i * 9
        local problem = rect_problem(buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7], buf[o + 8], buf[o + 9])
        if problem then return nil, problem end
      end
      for i = 0, n - 1 do
        local o = i * 9
        local id, err = paint_rect(g, buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7], buf[o + 8], buf[o + 9])
        if id == nil then return nil, err or "missing" end
        if ids then ids[i + 1] = id end
        if type(id) == "number" then d.ids[id] = true end
      end
      d.count = d.count + n
      return n
    end
    N.Gui.update_rect = function(g, id, x, y, z, w, h, r, gr, b, a)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      if not d.ids[id] then return nil, "not a rectangle of this GUI" end
      local problem = rect_problem(x, y, z, w, h, r, gr, b, a)
      if problem then return nil, problem end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.update_rect
      local p, s, c = make_vec3(x, y, z), make_vec2(w, h), make_color(a, r, gr, b)
      if type(fn) ~= "function" or not p or not s or not c then return nil, "missing" end
      local ok, err = pcall(fn, g, id, p, s, c)
      if not ok then return nil, err end
      return true
    end
    N.Gui.update_rects = function(g, ids, buf, n)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      if type(ids) ~= "table" or type(buf) ~= "table" or not whole(n, 0, 12000) or #buf < n * 9 or #ids < n then
        return nil, "invalid batch"
      end
      for i = 0, n - 1 do
        if not d.ids[ids[i + 1]] then return nil, "not a rectangle of this GUI" end
        local o = i * 9
        local problem = rect_problem(buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4], buf[o + 5], buf[o + 6], buf[o + 7], buf[o + 8], buf[o + 9])
        if problem then return nil, problem end
      end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.update_rect
      if type(fn) ~= "function" then return nil, "missing" end
      for i = 0, n - 1 do
        local o = i * 9
        local p, s, c = make_vec3(buf[o + 1], buf[o + 2], buf[o + 3]), make_vec2(buf[o + 4], buf[o + 5]), make_color(buf[o + 9], buf[o + 6], buf[o + 7], buf[o + 8])
        if not p or not s or not c then return nil, "missing" end
        local ok, err = pcall(fn, g, ids[i + 1], p, s, c)
        if not ok then return nil, err end
      end
      return n
    end
    N.Gui.set_visible = function(g, on)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not gui_of(g) then return nil, "GUI is not owned in a live world" end
      if type(on) ~= "boolean" then return nil, "visibility must be a boolean" end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.set_visible
      if type(fn) ~= "function" then return nil, "missing" end
      local ok, err = pcall(fn, g, on)
      if not ok then return nil, err end
      return true
    end
    N.Gui.text = function(g, s, font, size, x, y, z, r, gr, b, a)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      local problem = font_problem(s, font, size) or rect_problem(x, y, z, 1, 1, r, gr, b, a)
      if problem then return nil, problem end
      if d.count >= 12000 then return nil, "primitive limit reached" end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.text
      local p, c, idfont = make_vec3(x, y, z), make_color(a, r, gr, b), engine_font(font)
      if type(fn) ~= "function" or not p or not c or not idfont then return nil, "missing" end
      local ok, id = pcall(fn, g, s, idfont, size, FONT_MAT[font], p, c)
      if not ok or id == nil then return nil, ok and "missing" or id end
      d.count = d.count + 1
      if type(id) == "number" then d.texts[id] = true end
      return id
    end
    N.Gui.update_text = function(g, id, s, font, size, x, y, z, r, gr, b, a)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      if not d.texts[id] then return nil, "not a text of this GUI" end
      local problem = font_problem(s, font, size) or rect_problem(x, y, z, 1, 1, r, gr, b, a)
      if problem then return nil, problem end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.update_text
      local p, c, idfont = make_vec3(x, y, z), make_color(a, r, gr, b), engine_font(font)
      if type(fn) ~= "function" or not p or not c or not idfont then return nil, "missing" end
      local ok, err = pcall(fn, g, id, s, idfont, size, FONT_MAT[font], p, c)
      if not ok then return nil, err end
      return true
    end
    N.Gui.destroy_text = function(g, id)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local d = gui_of(g)
      if not d then return nil, "GUI is not owned in a live world" end
      if not d.texts[id] then return nil, "not a text of this GUI" end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.destroy_text
      if type(fn) ~= "function" then return nil, "missing" end
      local ok, err = pcall(fn, g, id)
      if not ok then return nil, err end
      d.texts[id] = nil
      return true
    end
    N.Gui.text_extents = function(g, s, font, size)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      if not gui_of(g) then return nil, "GUI is not owned in a live world" end
      local problem = font_problem(s, font, size)
      if problem then return nil, problem end
      local S = stingray_of()
      local fn = S and S.Gui and S.Gui.text_extents
      local idfont = engine_font(font)
      if type(fn) ~= "function" or not idfont then return nil, "missing" end
      local ok, lo, hi, caret = pcall(fn, g, s, idfont, size)
      if not ok then return nil, lo end
      local x0, y0 = pair_xy(lo)
      local x1, y1 = pair_xy(hi)
      local adv = pair_xy(caret)
      if not (finite(x0, 1e6) and finite(y0, 1e6) and finite(x1, 1e6) and finite(y1, 1e6) and finite(adv, 1e6)) then
        return nil, "unobserved result shape"
      end
      return x0, y0, x1, y1, adv
    end
    N.SteamLobby.set_member_data = function(a, b, c)
      if mod.phase ~= "active" then return nil, "mod is disabled" end
      local key = type(a) == "string" and a or b
      if type(key) ~= "string" or not string.match(key, "^[%w_]+$") or #key > 64 then
        return nil, "bad lobby key"
      end
      return guard(mod, "SteamLobby", "set_member_data")(a, b, c)
    end
    bind_rat_surface(N, mod, known_world, function() return frame_n end)
    return N
  end
  function public.mod(spec)
    if type(spec) ~= "table" then return nil, "spec is a table" end
    local id = spec.id
    if type(id) ~= "string" or not string.match(id, "^[%w_%.%-]+$") then return nil, "bad id" end
    if spec.api ~= nil and spec.api ~= 1 then return nil, "api 1 only" end
    if spec.lobby_key ~= nil and (type(spec.lobby_key) ~= "string" or not string.match(spec.lobby_key, "^[%w_]+$") or #spec.lobby_key > 32) then
      return nil, "bad lobby key"
    end
    if spec.bones ~= nil then
      if type(spec.bones) ~= "table" then return nil, "bones is a list of unit ids" end
      for i = 1, #spec.bones do
        local bone = spec.bones[i]
        if type(bone) ~= "string" or not string.match(bone, "^%x+$") or #bone ~= 16 then
          return nil, "bones is a list of unit ids"
        end
      end
    end
    if mods[id] then return mods[id] end
    local handle = {
      id = id, phase = "active", errors = 0, owned = {}, hidden = {}, zones = {}, hooks = {}, bones = spec.bones,
      lobby_key = spec.lobby_key,
    }
    handle.engine = engine_for(handle)
    handle.raw = rawget(_G, "stingray")
    handle.hooks = { update = {}, render = {}, shutdown = {} }
    function handle.on(event, fn)
      local list = handle.hooks[event]
      if type(list) ~= "table" then return nil, "unknown event " .. tostring(event) end
      if type(fn) ~= "function" then return nil, "callback is not a function" end
      if handle.phase ~= "active" then return nil, handle.phase end
      list[#list + 1] = fn
      return true
    end
    function handle.log(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      say(id .. ": " .. table.concat(parts, " "))
    end
    function handle.state() return handle.phase, handle.reason end
    function handle.switch_off(reason)
      if handle.phase ~= "active" then return end
      handle.phase = "off"
      handle.reason = tostring(reason or "switched off")
      if type(handle.rat_release) == "function" then pcall(handle.rat_release) end
      local S = rawget(_G, "stingray")
      for unit, world in pairs(handle.owned) do
        if world ~= nil and type(S) == "table" and type(S.World) == "table" and type(S.World.destroy_unit) == "function" then
          pcall(S.World.destroy_unit, world, unit)
        end
      end
      handle.owned = {}
      if type(S) == "table" and type(S.Unit) == "table" and type(S.Unit.set_unit_visibility) == "function" then
        for unit in pairs(handle.hidden) do pcall(S.Unit.set_unit_visibility, unit, true) end
      end
      handle.hidden = {}
      if type(handle.guis) == "table" and type(S) == "table" and type(S.World) == "table" and type(S.World.destroy_gui) == "function" then
        for g, info in pairs(handle.guis) do
          if type(info) == "table" then pcall(S.World.destroy_gui, info.world, g) end
        end
      end
      handle.guis = {}
      if type(S) == "table" and type(S.Mouse) == "table" and type(S.Mouse.set_dead_zone) == "function" then
        for index, zone in pairs(handle.zones) do
          pcall(S.Mouse.set_dead_zone, index, zone.mode, zone.size)
        end
      end
      handle.zones = {}
    end
    mods[id] = handle
    order[#order + 1] = handle
    return handle
  end
  function public.status()
    local list = {}
    for i = 1, #order do
      local h = order[i]
      list[i] = { id = h.id, state = h.phase, errors = h.errors }
    end
    return {
      mods = list, modules = {}, previous = { exists = false },
      log_dir = dir or "", log_prefix = "ordnance", log_files = {},
    }
  end
  function public.frame() return frame_n end
  hd2rt_dispatch = function(kind, dt)
    if kind == "update" then frame_n = frame_n + 1 end
    for i = 1, #order do
      local h = order[i]
      local list = h.hooks[kind]
      if h.phase == "active" and type(list) == "table" then
        for j = 1, #list do
          if h.phase ~= "active" then break end
          local ok, err = pcall(list[j], dt)
          if not ok then
            h.errors = h.errors + 1
            say(h.id .. " " .. kind .. ": " .. tostring(err))
          end
        end
      end
    end
    if kind == "shutdown" then
      for i = 1, #order do
        local h = order[i]
        if h.phase == "active" then h.switch_off("shutdown") end
      end
    end
  end
  if type(package.preload) ~= "table" then package.preload = {} end
  package.preload.hd2rt = function() return public end
  package.loaded.hd2rt = public
  if rawget(_G, "HD2Runtime") == nil then rawset(_G, "HD2Runtime", public) end
  say("hd2rt ready")
end

local function start()
  if L.started then return end
  L.started = true
  install_input_gate()
  install_hd2rt()
  for _, key in ipairs({ "update", "render", "shutdown" }) do
    if type(rawget(_G, key)) ~= "function" then rawset(_G, key, function() end) end
  end
  local ok, addons, guests, options = pcall(discover)
  if not ok then
    say("discovery failed: " .. tostring(addons))
    flush()
    return
  end
  local saved = {}
  for _, entry in ipairs(options or {}) do
    local ran, result = pcall(run_options, entry)
    if not ran then
      say("options " .. tostring(entry.name) .. ": " .. tostring(result))
    elseif type(result) == "table" then
      saved[entry.name] = merge_into(saved[entry.name], result)
    end
  end
  menu_api.use_options(saved)
  addons = order_addons(addons or {})
  for _, entry in ipairs(addons) do
    local ran, problem = pcall(run_addon, entry)
    if not ran then say(tostring(entry.name) .. ": " .. tostring(problem)) end
    flush()
  end
  for _, entry in ipairs(guests or {}) do
    local ran, problem = pcall(run_guest, entry)
    if not ran then say(tostring(entry.name) .. ": " .. tostring(problem)) end
    flush()
  end
  for _, fn in ipairs(after_startup) do
    local ran, problem = pcall(fn)
    if not ran then say("after_startup: " .. tostring(problem)) end
  end
  hook_shutdown()
  adopt_frame()
  say("menu hook installed")
  say("options menu rows: " .. menu_api.describe())
  menu_api.emit("startup")
  flush()
end

local game_init = rawget(_G, "init")
rawset(_G, "init", function(...)
  install_input_gate()
  local results = { n = 0 }
  if type(game_init) == "function" then
    local packed = { pcall(game_init, ...) }
    if packed[1] then
      results = { n = #packed - 1 }
      for i = 2, #packed do results[i - 1] = packed[i] end
    else
      say("game init: " .. tostring(packed[2]))
    end
  end
  local ok, why = pcall(start)
  if not ok then
    say("start failed: " .. tostring(why))
    flush()
  end
  return unpack(results, 1, results.n)
end)

say("waiting for init")
flush()
