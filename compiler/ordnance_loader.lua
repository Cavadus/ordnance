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
          local key = entry.kind .. ":" .. entry.name
          by_name[key] = entry
        end
      end
      pcall(function() file:close() end)
    end
  end
  for _, entry in pairs(by_name) do
    if entry.kind == "guest" or entry.kind == "boot" then guests[#guests + 1] = entry
    elseif entry.kind == "options" then options[#options + 1] = entry
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

-- Options menu. Mods receive their own chef table (local chef = ...). The
-- calls Chef's menu documents are here: option, bind, get, set, save, load.
-- Anything else logs and returns nil, and the mod keeps running.
local menu_api = (function()
  local settings, groups, group_of, rows = {}, {}, {}, {}
  local open, selected, scroll, capture = false, 1, 0, nil
  local gui, gui_world, drawn, draw_failed = nil, nil, {}, false
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

  local function load_settings()
    local path = settings_path()
    if path == nil then return end
    local ok, file = pcall(io.open, path, "r")
    if not ok or file == nil then return end
    for line in file:lines() do
      local owner, key, kind, data = string.match(line, "^([^\t]*)\t([^\t]*)\t([bns])\t(.*)$")
      if owner and key then
        settings[owner] = settings[owner] or {}
        settings[owner][key] = decode(kind, data)
      end
    end
    pcall(function() file:close() end)
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
    local ok, file = pcall(io.open, path, "w")
    if ok and file ~= nil then
      pcall(function() file:write(table.concat(lines, "\n")) if #lines > 0 then file:write("\n") end file:close() end)
    end
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

  local function suppress(on)
    local S = stingray()
    local K = S and S.Keyboard
    if type(K) ~= "table" then return end
    if on and not saved_input then
      saved_input = { pressed = K.pressed, button = K.button, keystrokes = K.keystrokes }
      K.pressed = function() return false end
      K.button = function() return 0 end
      if K.keystrokes ~= nil then K.keystrokes = function() return nil end end
    elseif not on and saved_input then
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
      local ok, err = pcall(row.changed[i], row.value)
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

  local function add_option(owner, id, spec)
    if type(id) ~= "string" or string.match(id, "^[%w_%.%-]+$") == nil then
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
      for j = 1, #g.rows do out[#out + 1] = { kind = "row", row = g.rows[j] } end
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

  local function combo_from(keyname)
    local mods = {}
    if mod_down("ctrl") then mods[#mods + 1] = "ctrl" end
    if mod_down("shift") then mods[#mods + 1] = "shift" end
    if mod_down("alt") then mods[#mods + 1] = "alt" end
    if #mods == 0 then return keyname end
    return table.concat(mods, "+") .. "+" .. keyname
  end

  local function update()
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
      end
      suppress(open)
      return
    end
    if not open then suppress(false) return end
    local list = lines()
    if selected > #list then selected = #list end
    if selected < 1 then selected = 1 end
    local row = list[selected] and list[selected].row
    for name in pairs(just) do
      if name == "up" or name == "up arrow" then move(-1)
      elseif name == "down" or name == "down arrow" then move(1)
      elseif name == "left" or name == "left arrow" then if row then nudge(row, -1) end
      elseif name == "right" or name == "right arrow" then if row then nudge(row, 1) end
      elseif name == "esc" or name == "escape" then open = false
      elseif (name == "enter" or name == "return") and row then
        local ty = row.spec.type
        if ty == "key" then capture = row
        elseif ty == "button" and type(row.spec.run) == "function" then
          local ok, err = pcall(row.spec.run)
          if not ok then say(row.owner .. " button " .. row.id .. ": " .. tostring(err)) end
        elseif ty == "toggle" then nudge(row, 1)
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

  local function render()
    local S = stingray()
    if not open or draw_failed then
      if S and gui and #drawn > 0 and type(S.Gui) == "table" then
        for i = 1, #drawn do
          local kind, id = drawn[i][1], drawn[i][2]
          if id ~= nil and type(S.Gui[kind]) == "function" then pcall(S.Gui[kind], gui, id) end
        end
        drawn = {}
      end
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
    local w, h = 1920, 1080
    if type(A.back_buffer_size) == "function" then
      local ok, bw, bh = pcall(A.back_buffer_size)
      if ok and type(bw) == "number" and type(bh) == "number" and bw > 0 and bh > 0 then w, h = bw, bh end
    end
    local scale = math.min(w / 1920, h / 1080)
    if scale <= 0 then scale = 1 end
    local list = lines()
    local window = 16
    if selected < scroll + 1 then scroll = selected - 1 end
    if selected > scroll + window then scroll = selected - window end
    if scroll < 0 then scroll = 0 end
    local shown = math.min(window, math.max(0, #list - scroll))
    local row_h = 26 * scale
    local panel_w = math.min(w - 48 * scale, 720 * scale)
    local panel_h = 48 * scale + shown * row_h
    local x = 28 * scale
    local top = h - 28 * scale
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
      local ok, id = pcall(S.Gui.text, gui, tostring(str), FONT, size, FONT, S.Vector2(px, py), c)
      if ok and id ~= nil then drawn[#drawn + 1] = { "destroy_text", id } end
    end
    rect(x, top - panel_h, panel_w, panel_h, bg, 40)
    text("Ordnance    " .. string.upper(menu_key()) .. " closes    arrows change    enter rebinds", x + 16 * scale, top - 28 * scale, 16 * scale, fg)
    for i = 1, shown do
      local item = list[scroll + i]
      local y = top - 44 * scale - i * row_h
      if item.kind == "title" then
        text(item.title, x + 16 * scale, y, 16 * scale, hi)
      else
        local mark = (scroll + i == selected) and "> " or "  "
        local label = item.row.spec.label or item.row.id
        if scroll + i == selected then rect(x + 8 * scale, y - 4 * scale, panel_w - 16 * scale, row_h, color(S, 50, 255, 196, 64), 41) end
        text(mark .. label, x + 16 * scale, y, 15 * scale, fg)
        text(show(item.row), x + panel_w - 180 * scale, y, 15 * scale, dim)
      end
    end
  end

  local function chef_for(owner)
    local chef = { version = "ordnance-loader-1", api = 1 }
    chef.capabilities = { menu = true, bindings = true }
    function chef.has(name) return chef.capabilities[name] == true end
    function chef.log(msg) say(owner .. ": " .. tostring(msg)) end
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

  return { chef_for = chef_for, update = update, render = render }
end)()

-- The engine keeps the update/render it finds when this chunk returns.
-- Installing them here, and pointing them at whatever mods installed
-- during init, is what makes F10 reach the menu.
local call_update, call_render
local function on_update(dt)
  local ok, err = pcall(menu_api.update)
  if not ok then say("menu: " .. tostring(err)) end
  if type(call_update) == "function" and call_update ~= on_update then return call_update(dt) end
end
local function on_render(...)
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
  if string.find(head, "--@@LOADER@@", 1, true)
    or string.find(head, "Chef Shared Loader", 1, true)
    or string.find(head, "Boot Mod Loader", 1, true)
    or string.find(head, "Rat's Shared Loader", 1, true) then
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
  if wants_chef(source) then
    local mine = menu_api.chef_for(entry.name)
    ran, result = xpcall(function() return chunk(mine) end, traceback)
  else
    ran, result = xpcall(chunk, traceback)
  end
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
  local ran, result = xpcall(chunk, traceback)
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
        local ok, problem = pcall(captured)
        if not ok then say(entry.name .. " init: " .. tostring(problem)) end
      else
        local previous = before[key]
        if previous == on_update then previous = call_update end
        if previous == on_render then previous = call_render end
        if type(previous) ~= "function" then previous = nil end
        rawset(_G, key, function(...)
          local ok, problem = pcall(captured, ...)
          if not ok then say(entry.name .. " " .. key .. ": " .. tostring(problem)) end
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
  if wants_chef(source) then
    local mine = menu_api.chef_for(entry.name)
    ran, result = xpcall(function() return chunk(mine) end, traceback)
  else
    ran, result = xpcall(chunk, traceback)
  end
  if not ran then
    say("options " .. entry.name .. ": FAILED: " .. tostring(result))
    return
  end
  if type(package) == "table" and type(package.loaded) == "table" then
    package.loaded[entry.name] = (result == nil) and true or result
  end
  say("options " .. entry.name .. " (patch_" .. entry.patch .. "): loaded")
end

local function hook_shutdown()
  if #on_shutdown == 0 then return end
  local previous = rawget(_G, "shutdown")
  if type(previous) ~= "function" then previous = nil end
  rawset(_G, "shutdown", function(...)
    local results, failed = { n = 0 }, nil
    if previous ~= nil then
      local packed = { pcall(previous, ...) }
      if packed[1] then
        results = { n = #packed - 1 }
        for i = 2, #packed do results[i - 1] = packed[i] end
      else
        failed = packed[2]
      end
    end
    for i, fn in ipairs(on_shutdown) do
      local ran, problem = pcall(fn)
      if not ran then say("on_shutdown " .. i .. ": " .. tostring(problem)) end
    end
    say(string.format("shutdown: %d on_shutdown function(s)", #on_shutdown))
    flush()
    if failed ~= nil then error(failed, 0) end
    return unpack(results, 1, results.n)
  end)
end

local function start()
  if L.started then return end
  L.started = true
  for _, key in ipairs({ "update", "render", "shutdown" }) do
    if type(rawget(_G, key)) ~= "function" then rawset(_G, key, function() end) end
  end
  local ok, addons, guests, options = pcall(discover)
  if not ok then
    say("discovery failed: " .. tostring(addons))
    flush()
    return
  end
  for _, entry in ipairs(options or {}) do
    local ran, problem = pcall(run_options, entry)
    if not ran then say("options " .. tostring(entry.name) .. ": " .. tostring(problem)) end
  end
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

call_update = rawget(_G, "update")
call_render = rawget(_G, "render")
if type(call_update) ~= "function" then call_update = nil end
if type(call_render) ~= "function" then call_render = nil end
rawset(_G, "update", on_update)
rawset(_G, "render", on_render)
say("waiting for init")
flush()
