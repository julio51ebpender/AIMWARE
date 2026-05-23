-- movement.lua
print(string.format(
    "[movement] APIs: entities=%s engine=%s client=%s gui=%s draw=%s input=%s globals=%s callbacks=%s Vector3=%s",
    tostring(entities  ~= nil),
    tostring(engine    ~= nil),
    tostring(client    ~= nil),
    tostring(gui       ~= nil),
    tostring(draw      ~= nil),
    tostring(input     ~= nil),
    tostring(globals   ~= nil),
    tostring(callbacks ~= nil),
    tostring(Vector3   ~= nil)
))

-- helpers
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function hsv_to_rgb(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    local r, g, b = 0, 0, 0
    local m = i % 6
    if     m == 0 then r, g, b = v, t, p
    elseif m == 1 then r, g, b = q, v, p
    elseif m == 2 then r, g, b = p, v, t
    elseif m == 3 then r, g, b = p, q, v
    elseif m == 4 then r, g, b = t, p, v
    else               r, g, b = v, p, q
    end
    return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

local _err_seen = {}
local function safe(label, fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok then
        local k = label .. "::" .. tostring(e)
        if not _err_seen[k] then
            _err_seen[k] = true
            print("[movement] ERROR " .. label .. ": " .. tostring(e))
        end
    end
end

-- Vector3 component access. aimware builds expose this differently:
-- some give methods (v:GetX()), some give fields (.x), some are indexed,
-- and once in a while the only thing that works is parsing tostring().
-- probe once, cache the winner, fall through pcall after that.
local _vget_method = nil

local function _parse_vec_str(v, axis)
    local s = tostring(v); if not s then return nil end
    local x, y, z = s:match("([%-%d%.eE+]+)[ ,]+([%-%d%.eE+]+)[ ,]+([%-%d%.eE+]+)")
    if not x then return nil end
    return tonumber(axis == "x" and x or (axis == "y" and y or z))
end

local _vget_fns = {
    method   = function(v, axis) return v["Get" .. axis:upper()](v) end,
    field    = function(v, axis) return v[axis] end,
    idx1     = function(v, axis) return v[axis == "x" and 1 or (axis == "y" and 2 or 3)] end,
    idx0     = function(v, axis) return v[axis == "x" and 0 or (axis == "y" and 1 or 2)] end,
    tostring = _parse_vec_str,
}
local _vget_order = { "method", "field", "idx1", "idx0", "tostring" }

local function vget(v, axis)
    if v == nil then return 0 end
    if _vget_method ~= nil then
        local ok, raw = pcall(_vget_fns[_vget_method], v, axis)
        if ok then local n = tonumber(raw); if n ~= nil then return n end end
        return 0
    end
    -- first call -- try each strategy until one returns a number
    for _, name in ipairs(_vget_order) do
        local ok, raw = pcall(_vget_fns[name], v, axis)
        if ok then
            local n = tonumber(raw)
            if n ~= nil then
                _vget_method = name
                print("[movement] vget: " .. name)
                return n
            end
        end
    end
    return 0
end

-- pre-create the verdana sizes we use anywhere on the hud
local FONTS = {}
for size = 11, 48 do
    FONTS[size] = draw.CreateFont("Verdana", size, 600)
end
local function font_for(size)
    size = math.floor(clamp(size, 11, 48))
    return FONTS[size] or FONTS[20]
end

local SCREEN_W, SCREEN_H = draw.GetScreenSize()
if (not SCREEN_W) or SCREEN_W < 100 then SCREEN_W = 1920 end
if (not SCREEN_H) or SCREEN_H < 100 then SCREEN_H = 1080 end

-- gui --
-- tooltip helper (SetDescription is build-dependent, hence the pcall)
local function _desc(w, t) if w and w.SetDescription then pcall(function() w:SetDescription(t) end) end end

-- best-effort accent override. scripts can't reliably reskin aimware
-- across every build, so try a few historic key names with pcall and
-- shrug if none of them stick.
local function _try_accent(r, g, b, a)
    if not gui or not gui.SetValue then return end
    for _, key in ipairs({
        "clr_gui_window_accent", "clr_window_accent",
        "clr_gui_accent",        "clr_accent",
        "Color_Accent",          "Skeet_Color",
    }) do
        pcall(gui.SetValue, key, r, g, b, a or 255)
    end
end
_try_accent(255, 178, 217, 255)  -- light pink

-- preset hud positions/sizes (1920x1080 base, scales to other resolutions)
local VNUM_SIZE        = 44    -- main number font size (px)
local VNUM_BRACKET_MUL = 0.65  -- bracket size as a fraction of VNUM_SIZE
local VNUM_BRACKET_GAP = 0.30  -- gap between number and bracket (* VNUM_SIZE)
local VNUM_CX          = math.floor(SCREEN_W * 0.5)
local VNUM_CY          = math.floor(SCREEN_H * 0.83)

-- velocity graph rect (menu groupbox is hidden but the draw code still
-- references this -- safe to leave as long as the stubs return false)
local VG_W = 480
local VG_H = 110
local VG_X = math.floor(SCREEN_W * 0.5 - VG_W * 0.5)
local VG_Y = math.floor(SCREEN_H * 0.92 - VG_H * 0.5)

-- window + groupboxes. two even columns, no overhang.
--   left  (10..300):  velocity number, jump trail
--   right (320..610): movement, null binds, debug
local WIN_W, WIN_H = 620, 380
local P = gui.Window("mv_window", "movement.lua", 100, 80, WIN_W, WIN_H)

-- velocity number (top-left)
local GB_VNUM    = gui.Groupbox   (P,        "Velocity Number", 10, 10, 290, 130)
local cb_vnum    = gui.Checkbox   (GB_VNUM,  "mv_vnum_e",  "Enable", true)
local cp_vnum    = gui.ColorPicker(GB_VNUM,  "mv_vnum_c",  "Number color",     255, 255, 255, 255)
local cp_vnum_jb = gui.ColorPicker(GB_VNUM,  "mv_vnum_jb", "Jump-speed color", 255, 178, 217, 255)
_desc(cb_vnum,    "Live speed in u/s. Pre-jump speed shows as ( N ) below.")
_desc(cp_vnum_jb, "Color of the ( N ) jump-speed bracket.")

-- jump trail (bottom-left)
local GB_TR     = gui.Groupbox   (P,       "Jump Trail", 10, 150, 290, 190)
local cb_tr     = gui.Checkbox   (GB_TR,   "mv_tr_e",   "Enable",       false)
local sl_tr_dur = gui.Slider     (GB_TR,   "mv_tr_dur", "Duration (s)", 5, 1, 15)
local sl_tr_thk = gui.Slider     (GB_TR,   "mv_tr_thk", "Thickness",    10, 1, 14)
local cb_tr_rgb = gui.Checkbox   (GB_TR,   "mv_tr_rgb", "RGB rainbow",  false)
local cp_tr     = gui.ColorPicker(GB_TR,   "mv_tr_c",   "Color",        255, 178, 217, 255)
_desc(cb_tr, "World-space glowing line; only renders during real jumps.")

-- movement (top-right)
local GB_MV     = gui.Groupbox(P,      "Movement", 320, 10, 290, 130)
local cb_eb     = gui.Checkbox(GB_MV,  "mv_eb_e",  "Smart edge bug", false)
local kb_eb     = gui.Keybox  (GB_MV,  "mv_eb_k",  "Edge-bug key", 0)
local cmb_eb_md = gui.Combobox(GB_MV,  "mv_eb_md", "Mode", "Hold", "Toggle")
_desc(cb_eb, "Auto +duck on the tick before landing. 5-point hull trace, hysteresis press/release, skips trivial drops to keep airaccel.")

-- null binds (middle-right)
local GB_NB = gui.Groupbox(P,     "Null Binds", 320, 150, 290, 70)
local cb_nb = gui.Checkbox(GB_NB, "mv_nb_e",    "Enable (W/A/S/D auto)", false)
_desc(cb_nb, "Resolves W+S and A+D; last-pressed key wins on each axis.")

-- debug (bottom-right)
local GB_DBG = gui.Groupbox(P,      "Debug", 320, 230, 290, 70)
local cb_dbg = gui.Checkbox(GB_DBG, "mv_dbg_e", "Live debug HUD overlay", false)
_desc(cb_dbg, "Top-left telemetry panel for diagnosing issues.")

-- velocity graph stubs -- not in the menu; the draw code reads these
-- and so it just never renders. to bring the panel back, replace with
-- real gui.Checkbox / gui.Slider / gui.ColorPicker calls.
local cb_vg    = { GetValue = function() return false             end }
local sl_vg_t  = { GetValue = function() return 2                 end }
local cp_vg    = { GetValue = function() return 255, 255, 255, 255 end }

-- constants
local KEY_W, KEY_S, KEY_A, KEY_D = 0x57, 0x53, 0x41, 0x44
local TRAIL_RAINBOW_DEG_PER_SEC  = 90

print("[movement] GUI built")

-- aimware menu open/close detection.
-- builds disagree on what api this lives behind, so probe a few names
-- and fall back to tracking INSERT (the default menu hotkey) if none
-- of them work.
local _menu_probe_done   = false
local _menu_method       = "none"

-- insert-key fallback
local KEY_INSERT         = 0x2D
local _ins_was_down      = false
local _ins_toggle        = true   -- assume visible at load; toggle on each press

local function _try_api(name)
    local fn = gui[name]
    if not fn then return false end
    local ok, r = pcall(fn)
    if ok and type(r) == "boolean" then
        _menu_method = name
        print("[movement] menu state via gui." .. name .. "()")
        return true
    end
    return false
end

local function detect_menu_method()
    _menu_probe_done = true
    -- documented + common variants
    local candidates = {
        "IsMenuOpen", "GetIsMenuOpen", "IsOpen", "IsOpened",
        "IsMenuVisible", "MenuOpen", "GetMenuOpen", "IsVisible",
    }
    for _, name in ipairs(candidates) do
        if _try_api(name) then return end
    end
    -- cheat.* table fallbacks
    if cheat then
        for _, name in ipairs({ "IsMenuOpen", "IsMenuVisible" }) do
            local fn = cheat[name]
            if fn then
                local ok, r = pcall(fn)
                if ok and type(r) == "boolean" then
                    _menu_method = "cheat_" .. name
                    print("[movement] menu state via cheat." .. name .. "()")
                    return
                end
            end
        end
    end
    print("[movement] no menu-state API found; using INSERT key fallback")
    _menu_method = "insert_fallback"
end

local function menu_is_open()
    if not _menu_probe_done then detect_menu_method() end

    -- always track INSERT so the user can manually toggle visibility
    -- even when the api path is working
    local now_down = input and input.IsButtonDown and input.IsButtonDown(KEY_INSERT) or false
    if now_down and not _ins_was_down then
        _ins_toggle = not _ins_toggle
    end
    _ins_was_down = now_down

    if _menu_method == "none" or _menu_method == "insert_fallback" then
        return _ins_toggle
    end

    local ok, r = pcall(function()
        if _menu_method:sub(1, 6) == "cheat_" then
            return cheat[_menu_method:sub(7)]()
        end
        return gui[_menu_method]()
    end)
    if not ok then _menu_method = "insert_fallback"; return _ins_toggle end
    return r and true or false
end

-- widget visibility.
-- the Window object and its children sometimes expose different setters,
-- so try them all and shrug if none stick.
local function set_vis(widget, visible)
    if not widget then return end
    if widget.SetInvisible then
        pcall(function() widget:SetInvisible(not visible) end)
        return
    end
    if widget.SetVisible then
        pcall(function() widget:SetVisible(visible) end)
        return
    end
    if widget.SetActive then
        pcall(function() widget:SetActive(visible) end)
        return
    end
end

local DEP_VNUM = { cp_vnum, cp_vnum_jb }
local DEP_TR   = { sl_tr_dur, sl_tr_thk, cb_tr_rgb, cp_tr }
local DEP_EB   = { kb_eb, cmb_eb_md }

local function apply_visibility()
    -- hide the script window when the aimware menu is closed
    set_vis(P, menu_is_open())

    for _, w in ipairs(DEP_VNUM) do set_vis(w, cb_vnum:GetValue()) end
    for _, w in ipairs(DEP_TR)   do set_vis(w, cb_tr:GetValue())   end
    for _, w in ipairs(DEP_EB)   do set_vis(w, cb_eb:GetValue())   end
end

-- shared state. read every CreateMove, consumed by draw + helpers.
--   jump_speed      2d speed snapshot at the takeoff impulse tick
--   jump_active     true between vz-impulse and confirmed landing
--   jump_clear_at   RealTime() the ( N ) bracket should disappear
--                   at; 0 means "hold indefinitely". on landing this
--                   becomes now+linger.
--   jump_takeoff_t  RealTime() of the impulse, used by the min-air
--                   guard so a flickery on_ground tick can't kill the
--                   trail in the first 100ms of a jump.
local state = {
    valid       = false,
    ox = 0, oy = 0, oz = 0,
    vz          = 0,
    speed_2d    = 0,
    on_ground   = false,
    on_ladder   = false,
    fall_speed  = 0,
    health      = 100,
    ground_dist = nil,
    jump_speed     = nil,
    jump_active    = false,
    jump_clear_at  = 0,
    jump_takeoff_t = 0,
}

local prev = {
    on_ground = true,
    speed_2d  = 0,
}

local trail, TRAIL_MAX, last_trail_t = {}, 1024, 0
-- graph: 100 samples * 50ms = 5s rolling window. heavy EMA + catmull-rom
-- in the draw step gives the smooth sinusoidal humps.
local graph, GRAPH_MAX, last_graph_t = {}, 100,  0
local _graph_ema = 0
-- floor pinned at 0; ceiling tracks the recent peak (asymmetric ema, see
-- draw_velocity_graph for the knobs).
local _vis_lo, _vis_hi = 0, 250

-- display-speed smoothing. position-delta velocity is tick-quantized so
-- the raw number ripples 5-15 u/s, which reads as "the digits are
-- flickering" especially around 250+ u/s. snap up on rises (peaks like
-- 320 during bhop need to be visible), ease down on falls so noise dips
-- don't show.
local _disp_speed  = 0
local DISP_DECAY_A = 0.18

local function reset_buffers()
    trail = {}; graph = {}; _graph_ema = 0
    _vis_lo, _vis_hi = 0, 250
    _disp_speed = 0
end

-- TraceLine probe. fed into the edge-bug ticks-to-impact math.
-- some builds expose engine.TraceLine, some only client.TraceLine,
-- some neither. probe once and remember which.
local _trace_method = nil
local function trace_down(ox, oy, oz, max_dist)
    if _trace_method == "none" then return nil end
    if _trace_method == nil then
        if engine and engine.TraceLine then _trace_method = "engine"
        elseif client and client.TraceLine then _trace_method = "client"
        else _trace_method = "none"; print("[movement] TraceLine unavailable; using gravity-math edge-bug"); return nil end
    end
    local dist
    local ok = pcall(function()
        local from = Vector3(ox, oy, oz - 1)
        local to   = Vector3(ox, oy, oz - max_dist)
        local tr
        if _trace_method == "engine" then tr = engine.TraceLine(from, to)
        else                              tr = client.TraceLine(from, to) end
        if tr and tr.fraction and tr.fraction < 1.0 then
            dist = (max_dist - 1) * tr.fraction
        end
    end)
    if not ok then _trace_method = "none"; return nil end
    return dist
end

-- multi-point ground distance for the edge bug.
-- the cs2 player hull is a 32x32 AABB so any of the four corners can
-- be the first thing to touch ground when crossing an edge. a center
-- trace alone lags the real contact by up to a full hull-radius, which
-- is exactly the timing the duck has to beat. sample center + 4 corners,
-- take the min, plug that into the kinematic solve.
local EB_HULL_HALF = 16
local EB_TRACE_MAX = 96

local function ground_dist_multi(ox, oy, oz)
    local d = trace_down(ox, oy, oz, EB_TRACE_MAX)
    local offs = { { -EB_HULL_HALF, -EB_HULL_HALF },
                   { -EB_HULL_HALF,  EB_HULL_HALF },
                   {  EB_HULL_HALF, -EB_HULL_HALF },
                   {  EB_HULL_HALF,  EB_HULL_HALF } }
    for i = 1, 4 do
        local s = trace_down(ox + offs[i][1], oy + offs[i][2], oz, EB_TRACE_MAX)
        if s and (not d or s < d) then d = s end
    end
    return d
end

-- ladder detection. read m_*MoveType if the build has GetPropInt;
-- otherwise fall back to a motion heuristic (sustained vertical velocity
-- without gravity-shaped accel == climbing). this matters because edge
-- bug + jump capture both need to be off on ladders or jumping off a
-- ladder gets eaten.
local _movetype_prop  = nil   -- nil = untried, false = unsupported, string = working prop name
local _ladder_streak  = 0
local LADDER_STREAK   = 4     -- consecutive ladder-shaped ticks before we believe it

local function _read_move_type(lp)
    if _movetype_prop == false then return nil end
    local function try(n)
        local r; pcall(function() r = lp:GetPropInt(n) end)
        return r
    end
    if _movetype_prop ~= nil then return try(_movetype_prop) end
    for _, n in ipairs({ "m_MoveType", "movetype", "m_nMoveType" }) do
        local r = try(n)
        if type(r) == "number" then
            _movetype_prop = n
            print("[movement] move type via GetPropInt('" .. n .. "')")
            return r
        end
    end
    _movetype_prop = false
    print("[movement] GetPropInt unsupported; using ladder heuristic")
    return nil
end

-- state update (CreateMove only).
-- this build of aimware only exposes GetAbsOrigin / GetHealth on the
-- local player -- no GetProp*, no GetVelocity. so velocity is derived
-- from position deltas with globals.TickInterval() as the dt.
--
-- airborne detection uses vz ACCELERATION not magnitude: walking up a
-- ramp keeps vz_accel near zero, falling tracks gravity (~-800), so
-- vz_accel inside the gravity window is the cleanest "airborne" signal.
local _state_announced = false
local _last_ox, _last_oy, _last_oz = nil, nil, nil
local _last_vz    = nil
local _gnd_stable = 0
local _air_stable = 0
local GROUND_TICKS      = 2     -- consecutive ground-shaped ticks needed
local AIR_TICKS         = 1     -- one gravity tick is enough to flip airborne
local GRAVITY_ACCEL_MIN = -1200 -- (~-800 in cs2)
local GRAVITY_ACCEL_MAX = -500
local GROUND_ACCEL_MAX  = 200   -- |accel| below this == surface-locked

-- forward decl: track_jump_speed installs the real impl on this so we
-- can wipe the vz-spike cache when the player invalidates
local _reset_jump_cache = function() end

local function _reset_motion_cache()
    _last_ox, _last_oy, _last_oz = nil, nil, nil
    _last_vz = nil
    _gnd_stable = 0
    _air_stable = 0
    _ladder_streak = 0
    _reset_jump_cache()
end

local function update_state()
    if state.valid then
        prev.on_ground = state.on_ground
        prev.speed_2d  = state.speed_2d
    end
    local was_valid = state.valid

    if entities == nil then
        state.invalid_reason = "no entities API"
        state.valid = false; return
    end

    local lp; pcall(function() lp = entities.GetLocalPlayer() end)
    if lp == nil then
        state.invalid_reason = "no local player (join a match)"
        state.valid = false
        _reset_motion_cache()
        if was_valid then reset_buffers() end
        return
    end

    local alive = false; pcall(function() alive = lp:IsAlive() end)
    if not alive then
        state.invalid_reason = "player not alive (spawn/respawn)"
        state.valid = false
        _reset_motion_cache()
        if was_valid then reset_buffers() end
        return
    end

    local origin; pcall(function() origin = lp:GetAbsOrigin() end)
    if origin == nil then
        state.invalid_reason = "GetAbsOrigin returned nil"
        state.valid = false; return
    end
    local ox, oy, oz = vget(origin, "x"), vget(origin, "y"), vget(origin, "z")

    local health = 100; pcall(function() health = lp:GetHealth() or 100 end)

    local tick_int = (globals.TickInterval and globals.TickInterval()) or (1/64)
    if tick_int <= 0 then tick_int = 1/64 end

    local vx, vy, vz = 0, 0, 0
    if _last_ox ~= nil then
        vx = (ox - _last_ox) / tick_int
        vy = (oy - _last_oy) / tick_int
        vz = (oz - _last_oz) / tick_int
    end
    _last_ox, _last_oy, _last_oz = ox, oy, oz

    local speed_2d = math.sqrt(vx * vx + vy * vy)

    -- gravity-acceleration ground detection
    local vz_accel = 0
    if _last_vz ~= nil then
        vz_accel = (vz - _last_vz) / tick_int
    end
    _last_vz = vz

    if (vz_accel < GRAVITY_ACCEL_MAX) and (vz_accel > GRAVITY_ACCEL_MIN) then
        _air_stable = _air_stable + 1
        _gnd_stable = 0
    elseif math.abs(vz_accel) < GROUND_ACCEL_MAX and math.abs(vz) < 80 then
        -- ground = small accel AND near-zero vz. without the |vz|<80
        -- clause a stalled prediction tick mid-jump (origin unchanged
        -- for one frame -> everything reads zero) could accumulate
        -- _gnd_stable and flip on_ground true mid-air, which then
        -- cleared jump_active and ate the trail.
        _gnd_stable = _gnd_stable + 1
        _air_stable = 0
    end
    local on_ground
    if _gnd_stable >= GROUND_TICKS  then on_ground = true
    elseif _air_stable >= AIR_TICKS then on_ground = false
    else on_ground = state.on_ground end

    -- if you're moving upward at >50 u/s you cannot be on ground.
    -- one more guard against detector noise on the rising phase.
    if vz > 50 then on_ground = false; _gnd_stable = 0 end

    -- ladder: prefer the engine prop, fall through to the heuristic
    local mt = _read_move_type(lp)
    local on_ladder
    if type(mt) == "number" then
        on_ladder = (mt == 9)
        _ladder_streak = on_ladder and LADDER_STREAK or 0
    else
        local climbing = (math.abs(vz) > 60) and (math.abs(vz_accel) < GROUND_ACCEL_MAX) and (speed_2d < 280)
        if climbing then _ladder_streak = math.min(_ladder_streak + 1, LADDER_STREAK)
        else             _ladder_streak = math.max(_ladder_streak - 1, 0) end
        on_ladder = _ladder_streak >= LADDER_STREAK
    end

    state.valid          = true
    state.invalid_reason = nil
    state.ox, state.oy, state.oz = ox, oy, oz
    state.vz         = vz
    state.speed_2d   = speed_2d
    state.on_ground  = on_ground
    state.on_ladder  = on_ladder
    state.fall_speed = (vz < 0) and -vz or 0
    state.health     = health
    state._dbg_vz_accel = vz_accel  -- debug hud only
    state._dbg_tick_int = tick_int

    -- ground_dist is only used by the edge-bug path. skip the traces
    -- when the feature's off, on a ladder, on the ground, or falling
    -- too slow to matter -- below 120 u/s there's no stamina or fall
    -- damage, so a +duck press is pure airaccel cost.
    if cb_eb:GetValue() and (not on_ground) and (not on_ladder)
       and vz < -40 and (-vz) >= 120 then
        state.ground_dist = ground_dist_multi(ox, oy, oz)
    else
        state.ground_dist = nil
    end

    if not was_valid then
        prev.on_ground = state.on_ground
        prev.speed_2d  = state.speed_2d
    end

    if not _state_announced then
        _state_announced = true
        print(string.format("[movement] state OK | speed=%.0f ground=%s health=%d",
            speed_2d, tostring(on_ground), health))
    end
end

-- snap-up / ease-down smoothing for the velocity number. see _disp_speed
-- comment up top. runs every CreateMove right after update_state.
local function update_disp_speed()
    if not state.valid then _disp_speed = 0; return end
    local target = state.speed_2d
    if target >= _disp_speed then
        _disp_speed = target                                              -- peak preserved
    else
        _disp_speed = _disp_speed + (target - _disp_speed) * DISP_DECAY_A -- ease down
    end
end

-- buffer pushers --
-- trail: push samples while jump_active is true, but trim-by-age runs
-- every tick regardless. that way after landing the trail keeps draining
-- from the oldest end pixel-by-pixel rather than vanishing in one frame.
local function trail_push(now)
    if not cb_tr:GetValue() then
        if #trail > 0 then trail = {} end                       -- feature off
        return
    end
    if not state.valid then return end

    local life = sl_tr_dur:GetValue()

    -- new samples only mid-jump
    if state.jump_active and (now - last_trail_t) >= 0.012 then
        last_trail_t = now
        trail[#trail + 1] = { x = state.ox, y = state.oy, z = state.oz, t = now }
        if #trail > TRAIL_MAX then table.remove(trail, 1) end
    end

    -- always trim by age -- this is what drains the tail after landing
    while #trail > 0 and (now - trail[1].t) > life do
        table.remove(trail, 1)
    end
end

-- graph: 20Hz decimate + EMA. a=0.10 gives a ~0.45s time constant so
-- the curve takes about half a sec to respond -- gentle sinusoidal
-- humps. catmull-rom in draw bridges the sparse samples.
local GRAPH_PUSH_DT = 0.050
local GRAPH_EMA_A   = 0.10

local function graph_push(now)
    if not cb_vg:GetValue() then return end       -- skip work entirely when off
    if now - last_graph_t < GRAPH_PUSH_DT then return end
    last_graph_t = now
    local cur = state.valid and state.speed_2d or 0
    _graph_ema = _graph_ema * (1 - GRAPH_EMA_A) + cur * GRAPH_EMA_A
    graph[#graph + 1] = _graph_ema
    if #graph > GRAPH_MAX then table.remove(graph, 1) end
end

-- smart edge bug --
local eb_b   = { last_key = false, toggle_on = false }
local eb_st  = { duck_held = false }

local function eb_active()
    if not cb_eb:GetValue() then
        eb_b.last_key = false; eb_b.toggle_on = false; return false
    end
    local key = kb_eb:GetValue()
    if key == 0 then return false end
    local down = input.IsButtonDown(key) and true or false
    local rising = down and not eb_b.last_key
    eb_b.last_key = down
    if cmb_eb_md:GetValue() == 1 then
        if rising then eb_b.toggle_on = not eb_b.toggle_on end
        return eb_b.toggle_on
    end
    return down
end

local function eb_press()
    if not eb_st.duck_held then
        eb_st.duck_held = true
        client.Command("+duck", true)
    end
end
local function eb_release()
    if eb_st.duck_held then
        eb_st.duck_held = false
        client.Command("-duck", true)
    end
end

-- ticks_to_land prediction. all inputs come from update_state, no api
-- calls in here -- cheap to run every CreateMove.
--
-- the source 2 server resolves the landing collision against the duck
-- input that arrived in the user command for the impact tick, so the
-- duck has to be pressed on the tick BEFORE impact. press window is
-- ~1.0..1.8 ticks ahead so we still beat the impact even with jitter,
-- release threshold is 2.5 so a transient prediction bump (e.g. an
-- air-strafe lifting us briefly) drops the duck immediately instead of
-- bleeding airaccel for several ticks.
local EB_PRESS_TICKS         = 1.8
local EB_RELEASE_TICKS       = 2.5
local EB_PRED_FUTURE_TICKS   = 2.0   -- lookahead used by the no-trace fallback
local EB_PRED_VZ_THRESHOLD   = 320   -- |vz| at lookahead -> definitely landing
local EB_GRAVITY             = 800

-- exact ticks-to-impact from d = v0*t + 0.5*g*t^2, solved for t.
-- returns nil if we have no ground_dist (caller uses the velocity
-- heuristic in that case).
local function ticks_to_land(tick_int)
    local d = state.ground_dist
    if not d then return nil end
    local v0    = state.fall_speed
    local disc  = v0 * v0 + 2 * EB_GRAVITY * d
    if disc < 0 then return nil end
    local t_sec = (-v0 + math.sqrt(disc)) / EB_GRAVITY
    if t_sec < 0 then t_sec = 0 end
    return t_sec / tick_int
end

local function should_duck()
    if not state.valid then return false end
    if state.on_ground   then return false end
    if state.on_ladder   then return false end
    if state.vz >= 0     then return false end           -- still rising
    if state.fall_speed < 120 then return false end      -- no stamina/fall-dmg under this; press is pure airaccel cost

    local tick_int = (globals.TickInterval and globals.TickInterval()) or (1/64)
    if tick_int <= 0 then tick_int = 1/64 end

    local t = ticks_to_land(tick_int)
    if t then
        -- hysteresis -- arm at <=PRESS, drop only past >RELEASE
        if eb_st.duck_held then return t <= EB_RELEASE_TICKS
        else                   return t <= EB_PRESS_TICKS end
    end

    -- no traceline -- velocity-only fallback. arm only when projected
    -- vz at the lookahead is big enough that a real impact is imminent.
    local future_vz = state.vz - EB_GRAVITY * tick_int * EB_PRED_FUTURE_TICKS
    return (-future_vz) >= EB_PRED_VZ_THRESHOLD
end

local function edgebug_run(active)
    if not active then eb_release(); return end
    if should_duck() then
        eb_press()
    else
        -- grounded or prediction window closed -> release
        eb_release()
    end
end

-- jump speed capture --
-- the obvious approach (trigger on ground->air transition) is broken
-- because the gravity-based ground detector lags 1-2 ticks behind the
-- actual takeoff -- by the time on_ground flips, you're already mid-air
-- and speed_2d on the previous tick wasn't the real takeoff value.
--
-- so instead: watch vz. a real jump is a clean upward impulse (~301 u/s
-- in cs2) where vz crosses from <=50 into the impulse window in a single
-- tick. that fires AT the takeoff frame, with the lateral velocity at
-- that exact moment which is what you actually want to see.
--
-- the upper bound exists to reject step-ups: a stair step computes as
-- vz = step_height/tick_int = 18/0.0156 = ~1150 u/s for one tick. real
-- jumps land in the 150..400 band. walked-off ledges produce no spike
-- at all -- they just decay into negative vz under gravity.
local JUMP_VZ_MIN          = 150
local JUMP_VZ_MAX          = 400
-- ( N ) bracket sticks around for LINGER_SECS after landing then fades
-- over LINGER_FADE_SECS so you can actually read the value. trail does
-- NOT use the linger -- that stops cleanly the moment ground is confirmed.
local JUMP_LINGER_SECS     = 2.5
local JUMP_LINGER_FADE_SECS = 0.5
-- min-air guard: ignore on_ground / on_ladder for the first 100ms after
-- the impulse. real jumps last 400-700ms so this never gets in the way,
-- but it absorbs any single-tick detector flicker so the trail can't get
-- killed mid-jump.
local JUMP_MIN_AIR         = 0.10

local _last_vz_for_jump = 0
_reset_jump_cache = function()
    _last_vz_for_jump   = 0
    state.jump_speed    = nil
    state.jump_active   = false
    state.jump_clear_at = 0
    state.jump_takeoff_t = 0
end

local function track_jump_speed()
    if not state.valid then return end
    local now = (globals.RealTime and globals.RealTime()) or 0

    -- on a ladder: stop sampling new trail points and stop the bracket.
    -- don't bulk-clear `trail` -- the trim in trail_push lets the existing
    -- tail fade out over `life` instead of vanishing in one frame. the
    -- min-air guard kills any spurious one-tick on_ladder reading.
    if state.on_ladder and (now - (state.jump_takeoff_t or 0)) > JUMP_MIN_AIR then
        state.jump_active   = false
        state.jump_speed    = nil
        state.jump_clear_at = 0
        _last_vz_for_jump   = state.vz
        return
    end

    local jumped = (_last_vz_for_jump <= 50)
                   and (state.vz > JUMP_VZ_MIN)
                   and (state.vz < JUMP_VZ_MAX)
    _last_vz_for_jump = state.vz

    if jumped then
        -- fresh takeoff: snapshot speed, arm jump_active, stamp the time
        -- so the min-air guard can protect the early phase.
        state.jump_speed     = state.speed_2d
        state.jump_active    = true
        state.jump_clear_at  = 0
        state.jump_takeoff_t = now
        return
    end

    -- real landing -- ground stable AND past the min-air window. this
    -- is the only path that clears jump_active during normal play.
    -- again, no bulk wipe of `trail`; the age-trim in trail_push is what
    -- drains the tail smoothly after the jump ends.
    if state.on_ground and (now - (state.jump_takeoff_t or 0)) > JUMP_MIN_AIR then
        if state.jump_active then
            state.jump_active   = false
            state.jump_clear_at = now + JUMP_LINGER_SECS
        end
        if state.jump_speed and state.jump_clear_at > 0 and now >= state.jump_clear_at then
            state.jump_speed    = nil
            state.jump_clear_at = 0
        end
    end
end

-- bracket alpha mul in [0,1]. 1.0 while jumping / fresh-landed, fades
-- to 0 over the last JUMP_LINGER_FADE_SECS of the linger window.
local function jump_speed_alpha()
    if state.jump_active or state.jump_clear_at == 0 then return 1.0 end
    local now = (globals.RealTime and globals.RealTime()) or 0
    local remaining = state.jump_clear_at - now
    if remaining >= JUMP_LINGER_FADE_SECS then return 1.0 end
    if remaining <= 0 then return 0.0 end
    return remaining / JUMP_LINGER_FADE_SECS
end

-- null binds --
local nb = {
    forced     = { forward = nil, back = nil, moveleft = nil, moveright = nil },
    pressed_at = {},
    last_state = {},
}

local function nb_set(direction, want_release)
    if want_release then
        if nb.forced[direction] ~= false then
            client.Command("-" .. direction, true); nb.forced[direction] = false
        end
    else
        if nb.forced[direction] ~= true then
            client.Command("+" .. direction, true); nb.forced[direction] = true
        end
    end
end

local function nb_sync(direction, phys_key)
    if nb.forced[direction] == nil then return end
    local held = phys_key ~= 0 and input.IsButtonDown(phys_key)
    if held then client.Command("+" .. direction, true)
    else         client.Command("-" .. direction, true) end
    nb.forced[direction] = nil
end

-- one axis. last-pressed-wins: when both keys are held, the more recent
-- press dominates and the opposite direction gets -direction'd so the
-- engine only sees one input.
local function nb_axis(label, key_pos, key_neg, dir_pos, dir_neg)
    local pos = input.IsButtonDown(key_pos) and true or false
    local neg = input.IsButtonDown(key_neg) and true or false
    local tick = (globals.TickCount and globals.TickCount()) or 0
    local kp, kn = label .. "p", label .. "n"
    if pos and not nb.last_state[kp] then nb.pressed_at[kp] = tick end
    if neg and not nb.last_state[kn] then nb.pressed_at[kn] = tick end
    nb.last_state[kp] = pos; nb.last_state[kn] = neg

    if pos and neg then
        local pa = nb.pressed_at[kp] or 0
        local na = nb.pressed_at[kn] or 0
        if pa >= na then nb_set(dir_pos, false); nb_set(dir_neg, true)
        else             nb_set(dir_pos, true);  nb_set(dir_neg, false) end
    else
        nb_sync(dir_pos, key_pos)
        nb_sync(dir_neg, key_neg)
    end
end

-- both axes auto-nulled when the toggle is on. the direction you're
-- traveling is the last-pressed key on each axis -- standard kz/bhop.
local function nullbinds_run()
    if cb_nb:GetValue() then
        nb_axis("h", KEY_D, KEY_A, "moveright", "moveleft")
        nb_axis("v", KEY_W, KEY_S, "forward",   "back")
    else
        nb_sync("moveleft", KEY_A); nb_sync("moveright", KEY_D)
        nb_sync("forward",  KEY_W); nb_sync("back",      KEY_S)
    end
end

local function nullbinds_disable_all()
    nb_sync("moveleft", KEY_A); nb_sync("moveright", KEY_D)
    nb_sync("forward",  KEY_W); nb_sync("back",      KEY_S)
end

-- drawing --
local function draw_velocity_number()
    if not cb_vnum:GetValue() then return end
    local size = VNUM_SIZE
    draw.SetFont(font_for(size))

    -- main number
    -- center via floor(x + 0.5) not plain floor(): plain floor biases
    -- the text 1px right when its pixel width is odd, which read as
    -- slightly-off-center.
    -- shown value is _disp_speed (smoothed), not state.speed_2d (raw,
    -- tick-quantized): the raw value ripples 5-15 u/s per tick and
    -- made the number look glitchy past 250+. _disp_speed snaps up so
    -- bhop peaks stay visible, eases down so falling values are stable.
    local shown = state.valid and _disp_speed or 0
    local txt = string.format("%d", math.floor(shown + 0.5))
    local tw, th = draw.GetTextSize(txt); tw = tw or 0; th = th or 0
    local cx, cy = VNUM_CX, VNUM_CY
    local x = math.floor(cx - tw * 0.5 + 0.5)
    local y = math.floor(cy - th * 0.5 + 0.5)
    draw.Color(0, 0, 0, 220);   draw.Text(x + 1, y + 1, txt); draw.Text(x + 2, y + 2, txt)
    local r, g, b, a = cp_vnum:GetValue()
    draw.Color(r, g, b, a);     draw.Text(x, y, txt)

    -- ( N ) bracket below the main number. lingers a couple seconds
    -- after landing then fades over the last LINGER_FADE_SECS.
    if state.jump_speed then
        local alpha_mul = jump_speed_alpha()
        if alpha_mul > 0.001 then
            local jsize = math.max(14, math.floor(size * VNUM_BRACKET_MUL))
            draw.SetFont(font_for(jsize))
            local jtxt = string.format("( %d )", math.floor(state.jump_speed + 0.5))
            local jtw = select(1, draw.GetTextSize(jtxt)) or 0
            local jx = math.floor(cx - jtw * 0.5 + 0.5)
            local jy = y + th + math.floor(size * VNUM_BRACKET_GAP)
            local shadow_a = math.floor(220 * alpha_mul)
            draw.Color(0, 0, 0, shadow_a)
            draw.Text(jx + 1, jy + 1, jtxt); draw.Text(jx + 2, jy + 2, jtxt)
            local jr, jg, jb, ja = cp_vnum_jb:GetValue()
            draw.Color(jr, jg, jb, math.floor(ja * alpha_mul))
            draw.Text(jx, jy, jtxt)
        end
    end
end

-- speed graph. y-axis anchored at 0 so standing still sits at the
-- bottom; the top auto-tracks the recent peak with an asymmetric ema
-- (fast on rises, slow on falls). result: walking 0->250 traces a clean
-- ramp top-to-bottom; bhop peaks expand the ceiling without flattening
-- the walking band.
local GRAPH_SUBDIV     = 10    -- catmull-rom sub-segments per source segment
local GRAPH_TOP_PAD    = 0.10  -- 10% headroom above peak
local GRAPH_TOP_MIN    = 100   -- floor for the ceiling (don't crush walking)
local GRAPH_TRACK_UP   = 0.18  -- ema factor on peaks rising  -> responsive
local GRAPH_TRACK_DOWN = 0.025 -- ema factor on peaks falling -> slow decay

-- catmull-rom: y at t in [0,1] between y1 and y2, with y0/y3 as tangents
local function _catmull_y(y0, y1, y2, y3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * (
        (2 * y1) +
        (-y0 + y2) * t +
        (2*y0 - 5*y1 + 4*y2 - y3) * t2 +
        (-y0 + 3*y1 - 3*y2 + y3) * t3
    )
end

-- update the floating ceiling from the buffer. floor is hard-locked at 0.
-- O(n) across the buffer, called once per draw call.
local function _update_vis_range()
    local n = #graph
    if n < 1 then return end
    local hi = 0
    for i = 1, n do
        local v = graph[i]
        if v > hi then hi = v end
    end
    hi = hi * (1 + GRAPH_TOP_PAD)
    if hi < GRAPH_TOP_MIN then hi = GRAPH_TOP_MIN end
    -- asymmetric ema -- track up fast, decay slow
    local a = (hi > _vis_hi) and GRAPH_TRACK_UP or GRAPH_TRACK_DOWN
    _vis_hi = _vis_hi * (1 - a) + hi * a
    _vis_lo = 0
end

local function draw_velocity_graph()
    if not cb_vg:GetValue() then return end
    local n = #graph
    if n < 2 then return end

    _update_vis_range()
    local span = _vis_hi
    if span < 1 then span = 1 end

    local gx, gy, gw, gh = VG_X, VG_Y, VG_W, VG_H
    local thk            = sl_vg_t:GetValue()
    local r, g, b, a     = cp_vg:GetValue()

    local denom = n - 1
    local function sx(i) return gx + (i - 1) / denom * gw end
    local function sy(i)
        local v = graph[i]
        local norm = v / span
        if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
        return gy + gh - norm * gh
    end

    -- build the catmull-rom point list. SUBDIV sub-points per source
    -- segment, sharing endpoints (so SUBDIV-1 added per segment except
    -- the last where we add SUBDIV).
    local pts_x, pts_y = {}, {}
    local count = 0
    for i = 1, n - 1 do
        local i0 = (i - 1 < 1) and 1 or (i - 1)
        local i1, i2 = i, i + 1
        local i3 = (i + 2 > n) and n or (i + 2)
        local y0, y1, y2, y3 = sy(i0), sy(i1), sy(i2), sy(i3)
        local x1, x2 = sx(i1), sx(i2)
        local steps = (i == n - 1) and GRAPH_SUBDIV or (GRAPH_SUBDIV - 1)
        for s = 0, steps do
            local t = s / GRAPH_SUBDIV
            count = count + 1
            pts_x[count] = x1 + (x2 - x1) * t
            pts_y[count] = _catmull_y(y0, y1, y2, y3, t)
        end
    end

    draw.Color(r, g, b, a)
    local thk_off_lo = -math.floor((thk - 1) * 0.5)
    local thk_off_hi = thk_off_lo + thk - 1
    for i = 2, count do
        local x1 = math.floor(pts_x[i - 1] + 0.5)
        local y1 = math.floor(pts_y[i - 1] + 0.5)
        local x2 = math.floor(pts_x[i]     + 0.5)
        local y2 = math.floor(pts_y[i]     + 0.5)
        for dy = thk_off_lo, thk_off_hi do
            draw.Line(x1, y1 + dy, x2, y2 + dy)
        end
    end
end

-- 3d-style jump trail: outer halo + mid glow + bright core, with a
-- segment-perpendicular "tube" thickness so it doesn't read as a flat
-- 2d line. distance to camera scales thickness for depth.
local function draw_jump_trail()
    if not cb_tr:GetValue() then return end
    -- render whenever the buffer has samples. new pushes stop at landing
    -- (jump_active gate in trail_push) but the age-trim keeps draining
    -- the tail, and this function just keeps drawing whatever is left
    -- with its natural per-segment alpha. that's the pixel-by-pixel
    -- fade from the oldest end after the jump ends.
    if not state.valid then return end
    local n = #trail
    if n < 2 then return end

    local now  = (globals.RealTime and globals.RealTime()) or 0
    local life = sl_tr_dur:GetValue()
    local thk  = sl_tr_thk:GetValue()
    local rgb  = cb_tr_rgb:GetValue()
    local br, bg, bb, ba = cp_tr:GetValue()

    -- project each world point with a depth scale -- closer points get
    -- a thicker line. distance to the player's origin is the proxy.
    local px, py, pz = state.ox, state.oy, state.oz
    local proj = {}
    for i = 1, n do
        local p = trail[i]
        local sx, sy
        local ok = pcall(function()
            sx, sy = client.WorldToScreen(Vector3(p.x, p.y, p.z))
        end)
        if ok and sx and sy then
            local dx = p.x - px; local dy = p.y - py; local dz = p.z - pz
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            -- 1.0 next to the player, ~0.35 at 1500u away
            local depth_scale = clamp(1 / (1 + dist / 800), 0.35, 1.0)
            proj[i] = { x = sx, y = sy, depth = depth_scale }
        else
            proj[i] = false
        end
    end

    -- thick line via parallel offsets perpendicular to the segment
    -- direction so it reads like a tube and not a vertical bar.
    local function thick_line(ax, ay, bx, by, half_thk, r, g, bb_, a)
        local dx, dy = bx - ax, by - ay
        local len = math.sqrt(dx*dx + dy*dy)
        if len < 0.5 then return end
        local nx = -dy / len
        local ny =  dx / len
        draw.Color(r, g, bb_, a)
        local steps = math.max(1, math.floor(half_thk))
        for s = -steps, steps do
            local off_x = math.floor(nx * s + 0.5)
            local off_y = math.floor(ny * s + 0.5)
            draw.Line(ax + off_x, ay + off_y, bx + off_x, by + off_y)
        end
    end

    -- 3 passes: outer halo (translucent) -> mid glow -> bright core
    local passes = {
        -- { thk_mul, alpha_mul, value_mul }
        { 3.5, 0.18, 0.45 },
        { 2.0, 0.55, 0.85 },
        { 1.0, 1.00, 1.00 },
    }

    for pi = 1, #passes do
        local p_thk_mul   = passes[pi][1]
        local p_alpha_mul = passes[pi][2]
        local p_val_mul   = passes[pi][3]

        for i = 2, n do
            local a = proj[i - 1]; local b = proj[i]
            if a and b then
                local age      = now - trail[i].t
                local fade     = clamp(1 - (age / life), 0, 1)
                local depth    = (a.depth + b.depth) * 0.5
                local seg_thk  = thk * p_thk_mul * depth
                local alpha    = math.floor(ba * fade * p_alpha_mul)
                -- alpha>=1 (not >3) so the very tail of the fade is
                -- still pixel-by-pixel and not a discrete cutoff
                if alpha >= 1 and seg_thk > 0.4 then
                    local cr, cg, cb_
                    if rgb then
                        local h = ((now * (TRAIL_RAINBOW_DEG_PER_SEC / 360)) + (i / n)) % 1
                        cr, cg, cb_ = hsv_to_rgb(h, 1, p_val_mul)
                    else
                        cr = math.floor(br * p_val_mul)
                        cg = math.floor(bg * p_val_mul)
                        cb_ = math.floor(bb * p_val_mul)
                    end
                    -- core pass: pure white inner highlight on top of the color
                    if pi == 3 then
                        cr = math.min(255, cr + 60)
                        cg = math.min(255, cg + 60)
                        cb_ = math.min(255, cb_ + 60)
                    end
                    thick_line(a.x, a.y, b.x, b.y, seg_thk * 0.5, cr, cg, cb_, alpha)
                end
            end
        end
    end
end

-- status / debug overlay.
-- bottom-left pill: only when state isn't valid (so the user can see
-- why the hud is empty). top-left debug hud: opt-in via the menu, lots
-- of telemetry for figuring out why something doesn't fire.
local function draw_status_pill()
    local show_invalid_pill = (not state.valid) and menu_is_open()
    local show_debug_hud    = cb_dbg:GetValue()
    if not show_invalid_pill and not show_debug_hud then return end

    draw.SetFont(font_for(13))

    if show_invalid_pill then
        local txt = "[movement] " .. (state.invalid_reason or "waiting for player...")
        draw.Color(0, 0, 0, 200);      draw.Text(11, SCREEN_H - 19, txt)
        draw.Color(255, 200, 80, 255); draw.Text(10, SCREEN_H - 20, txt)
    end

    if show_debug_hud then
        local lines = {
            string.format("speed_2d   = %.1f u/s   jump_speed = %s  active=%s",
                state.speed_2d,
                state.jump_speed and string.format("%.0f", state.jump_speed) or "nil",
                tostring(state.jump_active)),
            string.format("vz         = %.1f u/s   vz_accel = %.0f u/s^2",
                state.vz, state._dbg_vz_accel or 0),
            string.format("origin     = (%.1f, %.1f, %.1f)", state.ox, state.oy, state.oz),
            string.format("on_ground  = %s   on_ladder = %s   fall_speed = %.1f",
                tostring(state.on_ground), tostring(state.on_ladder), state.fall_speed),
            string.format("valid      = %s   health = %d   ground_dist = %s",
                tostring(state.valid), state.health, tostring(state.ground_dist)),
            string.format("trail=%d  graph=%d  tick=%.5f",
                #trail, #graph, state._dbg_tick_int or 0),
            string.format("graph ceiling = %.0f u/s  (floor locked at 0)", _vis_hi),
            string.format("vget=%s  trace=%s",
                tostring(_vget_method), tostring(_trace_method)),
            "----- edge bug -----",
            string.format("enabled=%s  key=0x%02X  active=%s  should_duck=%s  pressed=%s",
                tostring(cb_eb:GetValue()), kb_eb:GetValue(),
                tostring(eb_active()), tostring(should_duck()),
                tostring(eb_st.duck_held)),
            (function()
                local ti = (globals.TickInterval and globals.TickInterval()) or (1/64)
                local t  = ticks_to_land(ti)
                return string.format("ground_dist=%s  ticks_to_land=%s  fall=%.0f",
                    state.ground_dist and string.format("%.1f", state.ground_dist) or "nil",
                    t and string.format("%.2f", t) or "nil",
                    state.fall_speed)
            end)(),
        }

        local x, y      = 10, 50
        local line_h    = 15
        local panel_w   = 600
        local panel_h   = (#lines + 1) * line_h + 12
        draw.Color(0, 0, 0, 200);       draw.FilledRect(x - 4, y - 4, x + panel_w, y + panel_h)
        draw.Color(80, 80, 90, 220);    draw.OutlinedRect(x - 4, y - 4, x + panel_w, y + panel_h)
        draw.Color(255, 230, 120, 255); draw.Text(x, y, "[movement] live debug HUD")
        for i, ln in ipairs(lines) do
            draw.Color(220, 220, 220, 255); draw.Text(x, y + i * line_h + 2, ln)
        end
    end
end

-- callbacks --
local function on_create_move()
    safe("update_state", update_state)
    safe("disp_speed",   update_disp_speed)
    safe("edgebug",      edgebug_run, eb_active())
    safe("nullbinds",    nullbinds_run)
    safe("jump_speed",   track_jump_speed)
    local now = (globals.RealTime and globals.RealTime()) or 0
    safe("trail_push",   trail_push, now)
    safe("graph_push",   graph_push, now)
end

local function on_draw()
    safe("apply_vis",    apply_visibility)
    safe("draw_vnum",    draw_velocity_number)
    safe("draw_graph",   draw_velocity_graph)
    safe("draw_trail",   draw_jump_trail)
    safe("draw_status",  draw_status_pill)
end

local function on_unload()
    eb_release()
    nullbinds_disable_all()
    print("[movement] unloaded cleanly")
end

callbacks.Register("CreateMove", "mv_create_move", on_create_move)
callbacks.Register("Draw",       "mv_draw",        on_draw)
callbacks.Register("Unload",     "mv_unload",      on_unload)

print("[movement] loaded")

