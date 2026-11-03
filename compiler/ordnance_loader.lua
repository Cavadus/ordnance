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

-- Options menu. Mods receive their own chef table (local chef = ...). The
-- calls Chef's menu documents are here: option, bind, get, set, save, load.
-- Anything else logs and returns nil, and the mod keeps running.
local menu_api = (function()
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
    local fn = (saved_input and saved_input.button) or K.button
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
      drain_keystrokes(saved_input.keystrokes)
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
    local fn = (saved_input and saved_input.pressed) or (K and K.pressed)
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
  local function update()
    menu_frame = menu_frame + 1
    poll()
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
    if cmds.left and row then nudge(row, -1) end
    if cmds.right and row then nudge(row, 1) end
    if cmds.close then open, capture, nav_held = false, nil, {} end
    if cmds.enter then activate(row) end
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
    open, capture = false, nil
    suppress(false)
    drop_gui()
  end

  local function render()
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
    text("Ordnance    " .. string.upper(menu_key()) .. " closes    click or arrows    enter rebinds", x + 16 * scale, top - row_h, math.floor(18 * scale), fg)
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

  local option_sets = {}

  local function chef_for(owner)
    local chef = { version = "ordnance-loader-1", api = 1, options = option_sets[owner] or {} }
    chef.capabilities = { menu = true, bindings = true, option_headings = true }
    function chef.has(name) return chef.capabilities[name] == true end
    function chef.log(msg, ...)
      if type(msg) == "string" and select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, msg, ...)
        if ok then msg = formatted end
      end
      say(owner .. ": " .. tostring(msg))
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
    function chef.key_down(name) return key_down(string.lower(tostring(name or ""))) end
    function chef.key_pressed(name) return just[string.lower(tostring(name or ""))] == true end
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

  return { chef_for = chef_for, update = update, render = render, use_options = use_options, describe = describe, release = release }
end)()

-- Mods hook update while init runs, and they keep the function they find.
-- The menu is installed after those hooks, so it calls them and they call
-- the game. Installing it earlier makes the two call each other until the
-- game dies.
local call_update, call_render
local menu_update_said = false
local update_stopped, render_stopped = false, false
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
  local ok, err = pcall(menu_api.update)
  if not ok then say("menu: " .. tostring(err)) end
  if update_stopped or type(call_update) ~= "function" or call_update == on_update then return end
  dog_enter("update", 3)
  local ran, result = pcall(call_update, dt)
  dog_leave()
  if ran then return result end
  say("update: " .. tostring(result))
  if ran_too_long(result) then
    update_stopped = true
    say("update will not be called again this launch")
  end
end
local function on_render(...)
  if closing then return end
  if not render_stopped and type(call_render) == "function" and call_render ~= on_render then
    dog_enter("render", 3)
    local ran, result = pcall(call_render, ...)
    dog_leave()
    if not ran then
      say("render: " .. tostring(result))
      if ran_too_long(result) then render_stopped = true end
    end
  end
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

-- Option files return tables ({ ledger = true }, { kinds = { weapon = true } }).
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

local function start()
  if L.started then return end
  L.started = true
  dog_arm()
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
  for _, entry in ipairs(addons or {}) do
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
