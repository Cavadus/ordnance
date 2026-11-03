-- @@ORDNANCE@@ ordnance-loader-1
-- Ordnance starts Lua mods. One boot, plain Lua 5.1, no ffi.
-- It runs scripts declared the way Chef, Rat, and Boot Mod Loader find them:
--   -- HD2-Addon: mods/<author>/<name>
--   -- HD2-Boot: mods/<author>/<name>
--   -- HD2-Guest-Boot: <name>
--   -- HD2-Options: mods/<author>/<name>
-- A line `-- @loader rat` does not change that. The mod still starts.
-- File swaps are already on disk. This script does not copy .dl_bin files.

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

local chef = { version = "ordnance-loader-1" }
function chef.log(msg) say(tostring(msg)) end
setmetatable(chef, {
  __index = function(_, key)
    return function()
      say("chef." .. tostring(key) .. " is not provided; the mod keeps running")
      return nil
    end
  end,
})

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
    ran, result = xpcall(function() return chunk(chef) end, traceback)
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
  local ran, result = xpcall(chunk, traceback)
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
