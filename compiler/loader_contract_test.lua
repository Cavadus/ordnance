-- Public calls from Chef, Rat, and Boot Mod Loader.
-- A name that is missing, or a function that only answers "not available", fails.

local fails = 0
local function check(name, ok)
  if not ok then
    fails = fails + 1
    io.stderr:write("FAIL " .. name .. "\n")
  end
end

if type(newproxy) ~= "function" then
  io.stderr:write("FAIL newproxy\n")
  os.exit(1)
end

local tags = {}
local function ud(kind, label)
  local p = newproxy(true)
  getmetatable(p).__tostring = function()
    if kind == "Matrix4x4" then return label end
    if kind == "Vector3" then return "Vector3(1, 2, 3)" end
    if kind == "Quaternion" then return "Quaternion(0, 0, 0, 1)" end
    if kind == "Vector4" then return "Vector4(0, 0, 0, 1)" end
    return "[" .. kind .. "]"
  end
  tags[p] = label or kind
  return p
end

local zones = {}
local calls = { set_material = {}, set_local = {}, set_resource = {}, link = 0, join = 0, lobby = {} }
local quit = false
local gui_calls = {}
local bound_hex = nil
local KEY_DOWN = 8

local function id_of(v)
  if type(v) == "userdata" then return tags[v] end
  return v
end

local loaded = {
  ["unit:0011223344556677"] = true,
  ["material:aabbccddeeff0011"] = true,
  ["texture:1111111111111111"] = true,
  ["texture:2222222222222222"] = true,
  ["texture:3333333333333333"] = true,
  ["texture:4444444444444444"] = true,
  ["texture:5555555555555555"] = true,
}

_G.stingray = {
  Mouse = {
    num_axes = function() return 4 end,
    num_buttons = function() return 8 end,
    axis = function(i) return { x = i + 1, y = 5, z = 9 } end,
    axis_index = function(name)
      if name == "mouse" then return 0 end
      if name == "wheel" then return 1 end
    end,
    button = function(i) return i == 0 and 1 or 0 end,
    button_index = function(name) if name == "left" then return 0 end end,
    dead_zone = function(i)
      local z = zones[i]
      if not z then return 0, 0 end
      return z.mode, z.size
    end,
    set_dead_zone = function(i, mode, size) zones[i] = { mode = mode, size = size } end,
  },
  Keyboard = {
    num_buttons = function() return 16 end,
    button_index = function(name)
      if name == "f8" then return KEY_DOWN end
    end,
    pressed = function(i) return i == KEY_DOWN end,
    button = function(i) return i == KEY_DOWN and 1 or 0 end,
    keystrokes = function() return {} end,
  },
  Vector3 = setmetatable({
    to_elements = function(v)
      if type(v) == "table" then return v.x, v.y, v.z end
      return 1, 2, 3
    end,
    x = function() return 1 end,
    y = function() return 2 end,
    z = function() return 3 end,
  }, { __call = function(_, x, y, z) return { k = "v3", x = x, y = y, z = z } end }),
  Vector2 = setmetatable({}, { __call = function(_, x, y) return { k = "v2", x = x, y = y } end }),
  Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
  Math = { ray_box_intersection = function() return true end },
  Application = {
    quit = function() quit = true end,
    worlds = function() return { "world" } end,
    main_world = function() return "world" end,
    build = function() return "test" end,
    build_identifier = function() return "test-build" end,
    platform = function() return "linux" end,
    time_since_launch = function() return 1.5 end,
    resolution = function() return 1920, 1080 end,
    argv = function() return { "helldivers2" } end,
    can_get = function(kind, id)
      local hex = id_of(id)
      if type(hex) ~= "string" then return false end
      return loaded[kind .. ":" .. string.lower(hex)] == true
    end,
  },
  Unit = {
    alive = function(u) return type(u) == "userdata" and tags[u] ~= nil end,
    num_scene_graph_items = function() return 8 end,
    num_meshes = function() return 1 end,
    resource_name = function(u)
      if tags[u] == "cape" then return ud("IdString64", "3c33cf10a26cbb3e") end
      return ud("IdString64", "0011223344556677")
    end,
    world = function() return "world" end,
    id = function(u) return ud("IdString64", "0011223344556677") end,
    has_animation_state_machine = function() return true end,
    world_position = function() return ud("Vector3") end,
    world_rotation = function() return ud("Quaternion") end,
    world_pose = function() return ud("Matrix4x4", "Matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)") end,
    local_position = function() return ud("Vector3") end,
    local_rotation = function() return ud("Quaternion") end,
    local_scale = function() return ud("Vector3") end,
    local_pose = function() return ud("Matrix4x4", "Matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 9, 8, 7, 1)") end,
    has_node = function() return true end,
    node = function() return 3 end,
    mesh = function() return ud("Mesh") end,
    bones = function() return { chest = 1, cape1 = 2 } end,
    set_unit_visibility = function() end,
    set_mesh_visibility = function() end,
    set_local_position = function(u, node, value)
      calls.set_local[#calls.set_local + 1] = value
    end,
    set_local_rotation = function() end,
    set_local_scale = function() end,
    set_material = function(u, slot, mat)
      bound_hex = id_of(mat)
      calls.set_material[#calls.set_material + 1] = bound_hex
      return ud("IdString64", "7531dea9b2a2b888")
    end,
  },
  Mesh = {
    visibility = function() return true end,
    num_materials = function() return 3 end,
    material = function() return ud("Material") end,
    name = function() return "cape" end,
    material_slot_id = function() return ud("IdString32", "ffcdb65b") end,
    refresh_instance_hash = function() return ud("MeshObject") end,
  },
  Material = {
    id64 = function() return ud("IdString64", bound_hex or "7531dea9b2a2b888") end,
    set_scalar = function() end,
    set_vector2 = function() end,
    set_vector3 = function() end,
    set_vector4 = function() end,
    set_uint_vector = function() end,
    set_texture = function() end,
    set_resource = function(mat, variable, desc)
      calls.set_resource[#calls.set_resource + 1] = variable
    end,
    reinitialize_shader = function() end,
  },
  IdString64 = setmetatable({
    from_hex = function(s) return ud("IdString64", string.lower(s)) end,
    to_hex = function(v)
      if type(v) ~= "userdata" then error("native fault") end
      local hex = tags[v]
      if type(hex) ~= "string" then error("native fault") end
      return hex
    end,
  }, { __call = function(_, s) return ud("IdString64", tostring(s)) end }),
  IdString32 = {
    from_hex = function(s) return ud("IdString32", string.lower(s)) end,
    to_hex = function(v)
      if type(v) ~= "userdata" then error("native fault") end
      return tags[v]
    end,
  },
  World = {
    num_units = function(w) if w == "world" then return 3 end end,
    units = function() return {} end,
    units_by_resource = function() return {} end,
    create_screen_gui = function(w, mode, sx, sy)
      gui_calls.shape = { w, mode, sx, sy }
      return "gui"
    end,
    destroy_gui = function() gui_calls.destroyed = true end,
    spawn_unit = function()
      local u = ud("Unit", "spawned")
      return u
    end,
    destroy_unit = function() calls.units = (calls.units or 0) + 1 end,
    link_unit = function() calls.link = calls.link + 1 end,
    unlink_unit = function() end,
  },
  Gui = {
    rect = function(g, p, s, c)
      gui_calls.rect = { g, p, s, c }
      return 7
    end,
    update_rect = function() end,
    rects = function() return 7 end,
    update_rects = function() end,
    set_visible = function(g, on) gui_calls.vis = on end,
    text = function() return 3 end,
    update_text = function() end,
    destroy_text = function() end,
    text_extents = function()
      return { x = 0, y = -2 }, { x = 10, y = 8 }, { x = 11, y = 0 }
    end,
  },
  Window = {
    get_main_window = function() return ud("Window") end,
    has_focus = function() return true end,
    show_cursor = function() return false end,
    mouse_focus = function() return true end,
  },
  Renderer = {
    create_resource = function() return ud("Texture", "created") end,
    update_texture_base64 = function(desc, text, n) calls.upload = { text, n } end,
    destroy_resource = function() calls.destroyed = (calls.destroyed or 0) + 1 end,
  },
  Steam = { user_id = function() return "0123456789abcdef" end },
  Friends = {
    playing_game = function() return { app_id = 553850, lobby = "fedcba9876543210" } end,
  },
  Network = {
    join_steam_lobby = function(lobby)
      calls.join = calls.join + 1
      return ud("SteamLobby", lobby)
    end,
    game_session = function() return ud("GameSession") end,
    peer_id = function() return "0123456789abcdef" end,
    object_info = function()
      local fields = {}
      for i = 1, 72 do fields[i] = { id = "00000000", type = 0 } end
      fields[23] = { id = "8bbeb160", type = 3 }
      return { fields = fields }
    end,
  },
  SteamLobby = {
    state = function() return 2 end,
    members = function() return { "0123456789ABCDEF" } end,
    member_data = function() return "from-lobby" end,
    set_member_data = function(h, key, value) calls.lobby[#calls.lobby + 1] = { key, value } end,
  },
  GameSession = {
    in_session = function() return true end,
    peers = function() return { "0123456789abcdef" } end,
    objects_owned_by = function() return { 7 } end,
    game_object_exists = function() return true end,
    game_object_is_type = function() return true end,
    game_object_owner = function() return "0123456789abcdef" end,
    game_object_field = function()
      local p = ud("Vector3")
      p = p
      local v = newproxy(true)
      getmetatable(v).__tostring = function() return "Vector3(4, 5, 6)" end
      tags[v] = "pos"
      -- Vector3.x reads v.x; userdata has no fields, so the functions return 1, 2, 3.
      return v
    end,
  },
}

local function u32(n)
  local s = ""
  for i = 1, 4 do
    s = s .. string.char(n % 256)
    n = math.floor(n / 256)
  end
  return s
end
local function u64(n)
  return u32(n % 4294967296) .. u32(math.floor(n / 4294967296))
end

os.execute("rm -rf /tmp/contractgame && mkdir -p /tmp/contractgame/data /tmp/contractgame/bin/lua")
local src = "-- HD2-Addon: mods/ordnance/contract_probe\nlocal chef = ...\n_G.CONTRACT_CHEF = chef\nreturn { ping = function() return true end }\n"
local blob = u32(#src) .. u32(2) .. src
local row = string.rep("\0", 8)
  .. string.char(0xe2, 0x17, 0xd1, 0x2c, 0xfa, 0x8d, 0x4e, 0xa1)
  .. u64(0xB8)
  .. string.rep("\0", 32)
  .. u32(#blob)
  .. string.rep("\0", 20)
local patch = u32(0xF0000011) .. u32(1) .. u32(1) .. string.rep("\0", 0x48 - 12) .. string.rep("\0", 32) .. row .. blob
local out = io.open("/tmp/contractgame/data/9ba626afa44a3aa3.patch_0", "wb")
out:write(patch)
out:close()
package.path = "/tmp/contractgame/bin/lua/?.lua"

dofile("/home/lkavadas/clawd/ordnance/compiler/ordnance_loader.lua")
local init = rawget(_G, "init")
check("init installed", type(init) == "function")
init()

local chef = rawget(_G, "CONTRACT_CHEF")
check("probe ran", type(chef) == "table")
if type(chef) ~= "table" then
  print("FAILS " .. fails)
  os.exit(1)
end

local chef_names = {
  "TOP", "after", "after_startup", "api", "arc", "bind", "bitmap", "bitmap_uv", "budget", "button",
  "call", "call_kind", "camera", "capabilities", "capture", "circle", "cursor", "despawn", "emit",
  "every", "get", "has", "hold_mouse", "in_mission", "in_session", "index", "is_host", "joining",
  "key_down", "key_known", "key_label", "key_pressed", "lang", "light", "lights", "line", "link",
  "load", "load_table", "log", "log_directory", "log_file", "menu_open", "mission_kinds", "mods",
  "mouse_delta", "mouse_down", "mouse_held", "notify", "on", "on_change", "option", "options",
  "own_log", "particles", "peer_id", "players", "previous_directory", "ray_box", "rect", "require",
  "rgb", "ring", "save", "save_table", "screen", "set", "setting", "share", "shared", "spawn",
  "spread", "sprite", "sprite_sheet", "stop_particles", "text", "text_fit", "text_width", "text_wrap",
  "texture_sizes", "time", "title", "tr", "triangle", "typed", "ui_textures", "unit_alive", "unit_kind",
  "unit_node", "unit_position", "unit_rotation", "units_near", "unlink", "watch", "wheel", "world",
  "world_id", "world_to_screen",
}
check("chef name count", #chef_names == 98)
for i = 1, #chef_names do
  local name = chef_names[i]
  local a, b = chef[name], chef[name]
  check("chef." .. name, a ~= nil and a == b)
end
local r, g, b = chef.rgb("#ff0000")
check("rgb", r == 255 and g == 0 and b == 0)
check("has folds", chef.has("option_folds") == true)
check("has watchdog", chef.has("hang_watchdog") == false)
check("has ray", chef.has("ray_box") == true)
stingray.Math = nil
check("ray live off", chef.has("ray_box") == false)
stingray.Math = { ray_box_intersection = function() return true end }
check("ray live on", chef.has("ray_box") == true)
local wrote, err = pcall(function() chef.capabilities.api = false end)
check("capabilities locked", wrote == false and type(err) == "string" and string.find(err, "read-only", 1, true) ~= nil)
local held, held_why = chef.hold_mouse(true)
check("hold mouse", held == true and zones[0] ~= nil and zones[0].size == 917351)
check("release mouse", chef.hold_mouse(false) == true and zones[0].size == 0)
local vec = chef.call("Vector3", 1, 2, 3)
check("vector call", type(vec) == "table" and vec.x == 1 and vec.y == 2 and vec.z == 3)
local missing, missing_why = chef.require("mods/nope/nope")
check("require missing", missing == nil and type(missing_why) == "string" and string.find(missing_why, "not running", 1, true) ~= nil)
check("players", type(chef.players()) == "number")
check("host", type(chef.is_host()) == "boolean")
check("text fit", chef.text_fit("hi", 16, 1000) == "hi")
check("text wrap", type(chef.text_wrap("hello world", 16, 1000)) == "table")
check("key label", chef.key_label("f8") == "f8")
check("tr", chef.tr("x") == "x")
local ix, ix_why = chef.index()
check("index", ix == nil and ix_why == "building")
check("typed", type(chef.typed()) == "string")
local cap, cap_why = chef.capture()
check("capture", cap == nil and type(cap_why) == "string")

local mom, mbm = rawget(_G, "ModOptionsMenu"), rawget(_G, "ModBindingsMenu")
check("mom stable", mom.register_option == mom.register_option and mom.get == mom.get and mom.set == mom.set and mom.on_change == mom.on_change)
check("mom register", mom.register_option("contract_toggle", { type = "toggle", label = "Contract", default = false, mod = "Contract" }) == true)
check("mom get", mom.get("contract_toggle") == false)
local seen = nil
check("mom watch", mom.on_change("contract_toggle", function(v) seen = v end) == true)
check("mom set", mom.set("contract_toggle", true) == true and mom.get("contract_toggle") == true and seen == true)
check("mbm stable", mbm.register_binding == mbm.register_binding and mbm.is_down == mbm.is_down and mbm.poll == mbm.poll and mbm.set_binding == mbm.set_binding and mbm.binding == mbm.binding and mbm.binding_info == mbm.binding_info)
check("mbm register", mbm.register_binding("contract_key", "Contract key", nil, { default = "f8", category = "Contract" }) == true)
local info = mbm.binding_info("contract_key")
check("mbm default", type(info) == "table" and info.backend == "extended" and info.state == "default")
check("mbm down", mbm.is_down("contract_key") == true)
local polled = {}
check("mbm poll", mbm.poll({ "contract_key" }, polled) == true and polled.down[1] == true and polled.pressed[1] == true)
check("mbm clear", mbm.set_binding("contract_key", {}) == true and mbm.binding_info("contract_key").state == "cleared" and mbm.binding("contract_key")[1] == nil)
check("mbm missing", mbm.is_down("missing_binding") == nil)

local rt = require("hd2rt")
local handle = rt.mod({ id = "hd2tm", lobby_key = "hd2tm", bones = { "0011223344556677" } })
check("handle", type(handle) == "table" and handle.lobby_key == "hd2tm")
local eng = handle.engine
check("no passthrough", eng.Unit.launch_missile == nil and eng.Material.not_a_method == nil and eng.World.not_a_method == nil)

local rat = {
  Unit = { "alive", "num_scene_graph_items", "num_meshes", "resource_name", "world", "id", "has_animation_state_machine",
    "world_position", "world_rotation", "world_pose", "local_position", "local_rotation", "local_scale", "local_pose",
    "has_node", "node", "mesh", "set_unit_visibility", "set_mesh_visibility", "set_local_position", "set_local_rotation",
    "set_local_scale", "shift_native_cape", "set_material_at", "bones", "paint_private_cape", "restore_private_cape" },
  Mesh = { "visibility", "num_materials", "material", "name", "refresh_instance_hash" },
  Material = { "id64", "set_scalar", "set_vector2", "set_vector3", "set_vector4", "set_uint_vector", "set_texture",
    "private_aliases", "set_private_texture", "reinitialize_shader" },
  World = { "units", "num_units", "units_by_resource", "spawn_unit", "destroy_unit", "link_unit", "unlink_unit",
    "create_screen_gui", "destroy_gui" },
  Application = { "worlds", "can_get", "main_world", "build", "build_identifier", "platform", "time_since_launch",
    "resolution", "argv", "quit" },
  Keyboard = { "pressed", "keystrokes" },
  Mouse = { "num_axes", "num_buttons", "axis", "button", "dead_zone", "set_dead_zone" },
  Gui = { "rect", "rects", "update_rect", "update_rects", "set_visible", "text", "update_text", "destroy_text", "text_extents" },
  Window = { "ui_state" },
  Steam = { "user_id" },
  Friends = { "playing_game" },
  Network = { "join_steam_lobby" },
  SteamLobby = { "state", "members", "member_data", "set_member_data" },
  Texture = { "create", "collect", "release", "stats" },
  CharacterSession = { "snapshot" },
}
for ns, names in pairs(rat) do
  for i = 1, #names do
    local fn = eng[ns][names[i]]
    check(ns .. "." .. names[i], type(fn) == "function" and fn == eng[ns][names[i]])
    if names[i] ~= "quit" then
      local ok, a, why = pcall(fn)
      check(ns .. "." .. names[i] .. " answers", ok and not (a == nil and why == "not available"))
    end
  end
end
check("from_hex stable", eng.IdString64.from_hex == eng.IdString64.from_hex)
check("to_hex stable", eng.IdString64.to_hex == eng.IdString64.to_hex)

local cape_no, cape_why = eng.Unit.shift_native_cape("live")
check("shift bad unit", cape_no == nil and cape_why == "not a live unit")
local tex_no, tex_why = eng.Texture.create("nope")
check("texture name", tex_no == nil and tex_why == "name is not 16 hex characters")
local alias_no, alias_why = eng.Material.private_aliases("no")
check("aliases", alias_no == nil and alias_why == "expected a private ID list")
local link_no, link_why = eng.World.link_unit("nope")
check("link world", link_no == nil and link_why == "not a live world")
local lobby_no, lobby_why = eng.SteamLobby.set_member_data(nil, "hd2tm", "hi")
check("lobby handle", lobby_no == nil and lobby_why == "invalid lobby handle")
local friend_no, friend_why = eng.Friends.playing_game("nope")
check("steam id", friend_no == nil and friend_why == "invalid Steam id")
local saved_gs = stingray.GameSession
stingray.GameSession = nil
local snap_no, snap_why = eng.CharacterSession.snapshot()
check("session missing", snap_no == nil and snap_why == "Native character observation unavailable")
stingray.GameSession = saved_gs

local dz, dz_why = eng.Mouse.set_dead_zone(0, 1, 1)
check("dead zone near 1", dz == nil and type(dz_why) == "string" and zones[0].size == 0)
check("dead zone held", eng.Mouse.set_dead_zone(0, 1, 1000000) == true and zones[0].size == 1000000)
check("f8", eng.Keyboard.pressed("f8") == true)
check("f8 unknown", eng.Keyboard.pressed("not-a-key") == nil)
local spot = eng.Mouse.axis(2)
check("axis", type(spot) == "table" and spot.x == 3 and spot.y == 5 and spot.z == 9)
local saved_vector = stingray.Vector3
stingray.Vector3 = { to_elements = function(v) return { x = v.x, y = v.y, z = v.z } end }
local spot_box = eng.Mouse.axis(2)
check("axis boxed vector", type(spot_box) == "table" and spot_box.x == 3 and spot_box.y == 5 and spot_box.z == 9)
stingray.Vector3 = saved_vector
local saved_button = stingray.Mouse.button
stingray.Mouse.button = function() return true end
check("button bool", eng.Mouse.button(0) == 1)
stingray.Mouse.button = function() return false end
check("button bool up", eng.Mouse.button(1) == 0)
stingray.Mouse.button = saved_button
local ui = eng.Window.ui_state()
check("ui", type(ui) == "table" and ui.has_focus == true and ui.show_cursor == false and ui.mouse_focus == true)
stingray.Window.mouse_focus = function() return false end
local ui_play = eng.Window.ui_state()
check("mouse focus gameplay", ui_play.mouse_focus == true and ui_play.show_cursor == false and ui_play.has_focus == true)
stingray.Window.show_cursor = function() return true end
local ui_menu = eng.Window.ui_state()
check("mouse focus menu", ui_menu.mouse_focus == false and ui_menu.show_cursor == true)
stingray.Window.mouse_focus = function() return true end
stingray.Window.show_cursor = function() return false end
local function same_keys(got, ...)
  local want = { ... }
  if type(got) ~= "table" or #got ~= #want then return false end
  for i = 1, #want do if got[i] ~= want[i] then return false end end
  return true
end
stingray.Keyboard.keystrokes = function() return { 13, "fs", 8 } end
check("keys round trip", same_keys(eng.Keyboard.keystrokes(), 13, "fs", 8))
stingray.Keyboard.keystrokes = function() return { "\r", "ab", "\b" } end
check("keys controls", same_keys(eng.Keyboard.keystrokes(), 13, "ab", 8))
stingray.Keyboard.keystrokes = function() return { 13, "a", 300 } end
check("keys keep enter", same_keys(eng.Keyboard.keystrokes(), 13, "a"))
stingray.Keyboard.keystrokes = function() return "\nz" end
check("keys string enter", same_keys(eng.Keyboard.keystrokes(), 13, "z"))
stingray.Keyboard.keystrokes = function() return "typed", { 13, "fs" } end
check("keys second table", same_keys(eng.Keyboard.keystrokes(), 13, "fs"))
stingray.Keyboard.keystrokes = function() return {} end
local wide, high = eng.Application.resolution()
check("resolution", wide == 1920 and high == 1080)
local g = eng.World.create_screen_gui("world")
check("screen gui", g == "gui" and gui_calls.shape[2] == "scale" and gui_calls.shape[3] == 1)
check("rect", eng.Gui.rect(g, 1, 2, 3, 4, 5, 6, 7, 8, 9) == 7 and gui_calls.rect[4].a == 9 and gui_calls.rect[4].r == 6)
check("visible", eng.Gui.set_visible(g, false) == true)

local cape = ud("Unit", "cape")
check("shift", eng.Unit.shift_native_cape(cape, { chest = { 0.0625, 0, 0 } }) == true)
check("shift wrote", calls.set_local[1] ~= nil and math.abs(calls.set_local[1].x - 9.0625) < 1e-9 and calls.set_local[1].y == 8 and calls.set_local[1].z == 7)
local bones = eng.Unit.bones(ud("Unit", "spawned"))
check("bones", type(bones) == "table" and bones.chest == 1)
local bones_no, bones_why = eng.Unit.bones(cape)
check("bones other", bones_no == nil and bones_why == "unit resource not declared for bone names")

local declared = eng.Material.private_aliases({
  { id = "aabbccddeeff0011", slots = { "material_lut", "cape_lut", "cape_gradient", "decal_sheet", "cape_scalar_fields" } },
})
check("declare aliases", declared == true)
local fields = {
  material_lut = "1111111111111111", cape_lut = "2222222222222222", cape_gradient = "3333333333333333",
  decal_sheet = "4444444444444444", cape_scalar_fields = "5555555555555555",
}
local painted, paint_why = eng.Unit.paint_private_cape(cape, "aabbccddeeff0011", fields)
if painted ~= true then io.stderr:write("PAINT " .. tostring(paint_why) .. "\n") end
check("paint", painted == true)
check("paint bound", calls.set_material[#calls.set_material] == "aabbccddeeff0011")
local mesh_no, mesh_why = eng.Unit.mesh(cape, 1)
check("cape mesh closed", mesh_no == nil and mesh_why == "native cape reads require a fresh private transaction")
check("restore", eng.Unit.restore_private_cape(cape) == true)
check("restore bound", calls.set_material[#calls.set_material] == "7531dea9b2a2b888")

local pos = ud("Vector3")
local child = eng.World.spawn_unit("world", "0011223344556677", pos)
check("spawn", child ~= nil)
local parent = ud("Unit", "spawned")
local self_no, self_why = eng.World.link_unit("world", child, 1, child, 1)
check("link self", self_no == nil and self_why == "unit linked to itself")
local linked, link_why2 = eng.World.link_unit("world", child, 1, parent, 1)
check("link", linked == true and calls.link == 1)
check("set local", eng.Unit.set_local_position(child, 1, ud("Vector3")) == true)
local bad_value, bad_why = eng.Unit.set_local_position(child, 1, "nope")
check("set local kind", bad_value == nil and bad_why == "value is not a Vector3")
bound_hex = "aabbccddeeff0011"
local mesh = eng.Unit.mesh(child, 1)
local mat = eng.Mesh.material(mesh, 1)
local made = eng.Texture.create("abcdef0123456789", 1, 1, string.rep("\0", 8))
check("texture create", made == true and type(calls.upload) == "table" and calls.upload[2] == 8)
check("texture visible", eng.Application.can_get("texture", "abcdef0123456789") == true)
local stats = eng.Texture.stats()
check("texture stats", type(stats) == "table" and stats.live == 1 and stats.pending == 0)
local priv, priv_why = eng.Material.set_private_texture(mat, "material_lut", "abcdef0123456789")
if priv ~= true then io.stderr:write("PRIV " .. tostring(priv_why) .. "\n") end
check("private texture", priv == true)
check("private used resource", calls.set_resource[#calls.set_resource] == "material_lut")
local refreshed, refresh_why = eng.Mesh.refresh_instance_hash(mesh)
if refreshed ~= true then io.stderr:write("REFRESH " .. tostring(refresh_why) .. "\n") end
check("refresh", refreshed == true)
check("texture release", eng.Texture.release("abcdef0123456789") == true)
check("texture hidden", eng.Application.can_get("texture", "abcdef0123456789") == false)
local spare = eng.Texture.create("0123456789abcdef", 1, 1, string.rep("\0", 8))
check("spare texture", spare == true and eng.Texture.release("0123456789abcdef") == true)

local me = eng.Steam.user_id()
check("user", me == "0123456789abcdef")
local game = eng.Friends.playing_game(me)
check("playing", type(game) == "table" and game.lobby == "fedcba9876543210")
local lobby = eng.Network.join_steam_lobby(game.lobby)
check("join", calls.join == 1 and type(lobby) == "userdata")
check("join again", eng.Network.join_steam_lobby(game.lobby) == lobby)
local joined_no, joined_why = eng.Network.join_steam_lobby("0011223344556677")
check("join other", joined_no == nil and joined_why == "not the reported lobby")
check("member write", eng.SteamLobby.set_member_data(lobby, "hd2tm", "hi") == true and calls.lobby[#calls.lobby][1] == "hd2tm" and calls.lobby[#calls.lobby][2] == "hi")
local key_no, key_why = eng.SteamLobby.set_member_data(lobby, "other", "hi")
check("member key", key_no == nil and key_why == "not this mod's lobby key")
check("member read", eng.SteamLobby.member_data(lobby, me, "hd2tm") == "from-lobby")
check("lobby state", eng.SteamLobby.state(lobby) == 2)
local members = eng.SteamLobby.members(lobby)
check("members", type(members) == "table" and members[1] == "0123456789abcdef")

local snap, snap_err = eng.CharacterSession.snapshot()
if type(snap) ~= "table" then io.stderr:write("SNAP " .. tostring(snap) .. " " .. tostring(snap_err) .. "\n") end
check("snapshot", type(snap) == "table" and snap.peer == "0123456789abcdef" and snap.members == 1 and snap.objects[1].id == 7 and snap.objects[1].position[1] == 1 and snap.objects[1].position[2] == 2 and snap.objects[1].position[3] == 3)

_G.update(0.016)
_G.update(0.016)
check("collect", eng.Texture.collect() == 1 and calls.destroyed == 1)

handle.switch_off("test")
check("zone restored", zones[0].size == 0)
local off, off_why = eng.Unit.alive(cape)
check("disabled", off == nil and off_why == "mod is disabled")
check("quit not called", quit == false)

local exit_mod = rt.mod({ id = "exit_probe", bones = { "0011223344556677" } })
local exit_eng = exit_mod.engine
local exit_cape = ud("Unit", "cape")
check("exit aliases", exit_eng.Material.private_aliases({
  { id = "aabbccddeeff0011", slots = { "material_lut", "cape_lut", "cape_gradient", "decal_sheet", "cape_scalar_fields" } },
}) == true)
bound_hex = "7531dea9b2a2b888"
check("exit shift", exit_eng.Unit.shift_native_cape(exit_cape, { chest = { 0.0625, 0, 0 } }) == true)
local exit_painted, exit_paint_why = exit_eng.Unit.paint_private_cape(exit_cape, "aabbccddeeff0011", fields)
if exit_painted ~= true then io.stderr:write("EXIT PAINT " .. tostring(exit_paint_why) .. "\n") end
check("exit paint", exit_painted == true)
local exit_unit = exit_eng.World.spawn_unit("world", "0011223344556677", pos)
check("exit spawn", exit_unit ~= nil)
local exit_gui = exit_eng.World.create_screen_gui("world")
check("exit gui", exit_gui ~= nil)
local exit_heard = false
check("exit listen", exit_mod.on("shutdown", function() exit_heard = true end) == true)
local units_at = calls.units or 0
local mats_at = #calls.set_material
local locals_at = #calls.set_local
local tex_at = calls.destroyed or 0
gui_calls.destroyed = false
local shutdown_fn = rawget(_G, "shutdown")
check("shutdown installed", type(shutdown_fn) == "function")
if type(shutdown_fn) == "function" then shutdown_fn() end
check("exit heard", exit_heard == true)
check("exit left units", (calls.units or 0) == units_at)
check("exit left gui", gui_calls.destroyed ~= true)
check("exit left materials", #calls.set_material == mats_at)
check("exit left bones", #calls.set_local == locals_at)
check("exit left textures", (calls.destroyed or 0) == tex_at)

if fails == 0 then print("CONTRACT_OK") else print("FAILS " .. fails) os.exit(1) end
