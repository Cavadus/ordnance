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
      world = nil, world_n = 0, mission = false, mission_at = 0,
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

    local function bitmap(tex, x, y, w, h, c, layer)
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
      local okb = pcall(S.Gui.bitmap, e.gui, mat, p, s, c)
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
      if not obj then return nil end
      local t = S[obj]
      if type(t) ~= "table" then return nil end
      local fn = t[meth]
      if type(fn) ~= "function" then return nil end
      return fn
    end

    local function call_engine(name, ...)
      local fn = engine_fn(name)
      if not fn then return nil, "missing" end
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
      chef.log_directory = dir
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
        if not world_now() then return 0 end
        return R.world_n
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
      function chef.call_kind(name, kind, ...) return call_engine(name, ...) end
    end

    local function adopt(name, result)
      if type(result) ~= "table" then return end
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

    local function drive(kind, dt)
      if R.stopped then return end
      if kind == "shutdown" then
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
    end

    return { drive = drive, adopt = adopt, attach = attach }
  end)()

  local option_sets = {}

  local function chef_for(owner)
    local chef = { version = "ordnance-loader-1", api = 1, options = option_sets[owner] or {} }
    chef.capabilities = { menu = true, bindings = true, option_headings = true }
    function chef.has(name) return chef.capabilities[name] == true end
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
    setmetatable(chef, {
      __index = function(_, key)
        return function()
          say(owner .. " chef." .. tostring(key) .. " is not provided; the mod keeps running")
          return nil
        end
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
    api = 1, version = 4, capacity = 36 * MOM_MODS, window = "Ordnance options menu",
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

  return { chef_for = chef_for, adopt = runtime.adopt, update = update, render = render, use_options = use_options, describe = describe, release = release, blocking = blocking }
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
  dog_enter(entry.name, 10)
  local ran, result = xpcall(chunk, traceback)
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
          if previous ~= nil then return previous(...) end
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

local function start()
  if L.started then return end
  L.started = true
  install_input_gate()
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
