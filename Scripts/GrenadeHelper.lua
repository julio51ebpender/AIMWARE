-- Grenade Helper V6 - v1.2
-- Credits:
-- ShadyRetard - Grenade Helper base
-- Carter Poe & Agentsix1 - V6 API understanding
-- Ginette - Script optimization & AI reconstruction

local math_max, math_min, math_floor, math_sqrt, math_cos, math_sin, math_rad, math_atan2 = 
    math.max, math.min, math.floor, math.sqrt, math.cos, math.sin, math.rad, math.atan2
local string_byte, string_gmatch, string_gsub, string_lower, string_find, string_format =
    string.byte, string.gmatch, string.gsub, string.lower, string.find, string.format
local table_insert, table_remove, table_concat = table.insert, table.remove, table.concat
local bit_lshift, bit_bor, bit_band, bit_bnot = bit.lshift, bit.bor, bit.band, bit.bnot
local pairs, ipairs, type, tostring, tonumber, pcall = pairs, ipairs, type, tostring, tonumber, pcall

local draw_Color, draw_FilledRect, draw_Line, draw_TextShadow, draw_GetTextSize, draw_GetScreenSize, draw_OutlinedRect
local client_WorldToScreen, client_AllowListener
local entities_GetLocalPlayer
local globals_TickCount
local engine_GetMapName
local input_IsButtonDown, input_IsButtonPressed

local GH = {
    VERSION = "1.2",
    
    THROW_RADIUS = 20,
    THROW_RADIUS_SQ = 400,
    THROW_RADIUS_HALF = 10,
    DRAW_MARKER_DISTANCE = 100,
    ACTION_COOLDOWN = 30,
    NOTIF_DURATION = 220,
    WALKBOT_TIMEOUT = 300,
    WALKBOT_STOP_DISTANCE_SQ = 0.25,
    
    DEG_TO_RAD = 0.017453292519943,
    PI = 3.14159265359,
    TWO_PI = 6.28318530718,
    
    SAVE_FILE = "grenade_helper_data.dat",
    DATA_URL = "https://raw.githubusercontent.com/julio51ebpender/AIMWARE/refs/heads/main/Maps/grenade_helper_data.dat",
    SCRIPT_URL = "https://raw.githubusercontent.com/julio51ebpender/AIMWARE/refs/heads/main/Scripts/GrenadeHelper.lua",
    SCRIPT_NAME = "Grenade Helper.lua",
    
    IN_FORWARD = bit_lshift(1, 3),
    IN_BACK = bit_lshift(1, 4),
    IN_MOVELEFT = bit_lshift(1, 9),
    IN_MOVERIGHT = bit_lshift(1, 10),
    
    POSITION_TYPES = {"stand", "jump", "run", "crouch", "jump + crouch", "run + jump"},
    LAUNCH_TYPES = {"left", "right", "left + right"},
    GRENADE_IDS = {
        [43] = "flashbang", [44] = "hegrenade", [45] = "smokegrenade",
        [46] = "molotovgrenade", [47] = "decoy", [48] = "molotovgrenade"
    },
    
    maps = {},
    current_map = nil,
    last_action = 0,
    screen_w = 0,
    screen_h = 0,
    checking_update = false,
    local_data_hash = "",
    remote_data_hash = "",
    local_script_hash = "",
    remote_script_hash = "",
    update_window = nil,
    updates_found = {},
    jumpthrow_stage = 0,
    jumpthrow_tick = 0,
    notifications = {},
    
    walkbot = {
        active = false,
        target_x = 0, target_y = 0, target_z = 0,
        target_nade = nil,
        start_time = 0
    },
    
    cache = {
        colors = {},
        color_tick = 0
    },
    
    ui = {}
}

GH.MOVE_MASK = bit_bnot(bit_bor(GH.IN_FORWARD, GH.IN_BACK, GH.IN_MOVELEFT, GH.IN_MOVERIGHT))
GH.FORWARD_LEFT = bit_bor(GH.IN_FORWARD, GH.IN_MOVELEFT)

GH.has_http = type(http) == "table" and type(http.Get) == "function"
GH.has_file = type(file) == "table"
GH.has_file_open = GH.has_file and type(file.Open) == "function"
GH.has_file_write = GH.has_file and type(file.Write) == "function"
GH.has_file_enum = GH.has_file and type(file.Enumerate) == "function"

function GH:cacheAPI()
    draw_Color = draw.Color
    draw_FilledRect = draw.FilledRect
    draw_Line = draw.Line
    draw_TextShadow = draw.TextShadow
    draw_GetTextSize = draw.GetTextSize
    draw_GetScreenSize = draw.GetScreenSize
    draw_OutlinedRect = draw.OutlinedRect
    client_WorldToScreen = client.WorldToScreen
    client_AllowListener = client.AllowListener
    entities_GetLocalPlayer = entities.GetLocalPlayer
    globals_TickCount = globals.TickCount
    engine_GetMapName = engine.GetMapName
    input_IsButtonDown = input.IsButtonDown
    input_IsButtonPressed = input.IsButtonPressed
end

function GH:clamp(x, a, b)
    return x < a and a or (x > b and b or x)
end

local canon_patterns = {
    {"\\", "/"}, {"^maps/", ""}, {"%.bsp$", ""}, {"%.vpk$", ""}, {"%.zip$", ""}, {"^.*/", ""}
}

function GH:canonMapName(s)
    if not s or s == "" then return "" end
    s = string_lower(tostring(s))
    for i = 1, 6 do
        local p = canon_patterns[i]
        s = string_gsub(s, p[1], p[2])
    end
    return s
end

function GH:normalizeAngles(p, y)
    return (p < -89 and -89 or (p > 89 and 89 or p)), (y + 180) % 360 - 180
end

function GH:anglesToForward(p, y)
    local rp, ry = p * self.DEG_TO_RAD, y * self.DEG_TO_RAD
    local cp, sp = math_cos(rp), math_sin(rp)
    return cp * math_cos(ry), cp * math_sin(ry), -sp
end

function GH:toNum2(a)
    if not a then return 0, 0 end
    local p, y
    if type(a) == "userdata" then
        p, y = tonumber(a.pitch) or 0, tonumber(a.yaw) or 0
    elseif type(a) == "table" then
        p = tonumber(a.pitch or a.x or a[1]) or 0
        y = tonumber(a.yaw or a.y or a[2]) or 0
    else
        return 0, 0
    end
    return self:normalizeAngles(p, y)
end

function GH:getOriginXYZ(e)
    if not e then return 0, 0, 0 end
    local o = e:GetAbsOrigin()
    if not o then return 0, 0, 0 end
    if type(o) == "userdata" then
        return o.x, o.y, o.z
    elseif type(o) == "table" then
        return o.x or o[1] or 0, o.y or o[2] or 0, o.z or o[3] or 0
    end
    return 0, 0, 0
end

function GH:dist3DSq(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx*dx + dy*dy + dz*dz
end

function GH:dist3D(ax, ay, az, bx, by, bz)
    return math_sqrt(self:dist3DSq(ax, ay, az, bx, by, bz))
end

function GH:getVelocity(m)
    if not m or not m.GetFieldVector then return 0 end
    local v = m:GetFieldVector("m_vecAbsVelocity")
    return v and math_floor(math_min(10000, v:Length2D() + 0.5)) or 0
end

function GH:simpleHash(s)
    if not s or s == "" then return 0 end
    local h, len = 0, #s
    for i = 1, len do
        h = (h * 31 + string_byte(s, i)) % 2147483647
    end
    return h
end

function GH:getActiveGrenadeName()
    local m = entities_GetLocalPlayer()
    if not m or (m.IsAlive and not m:IsAlive()) then return nil end
    local w = m.GetWeaponID and m:GetWeaponID()
    return w and self.GRENADE_IDS[w]
end

function GH:addNotification(t, r, g, b)
    self.notifications[#self.notifications + 1] = {
        text = t, r = r or 255, g = g or 255, b = b or 255,
        expire = globals_TickCount() + self.NOTIF_DURATION
    }
end

function GH:drawNotifications()
    local notifs = self.notifications
    local count = #notifs
    if count == 0 then return end
    
    local tick = globals_TickCount()
    local cx, yo = self.screen_w * 0.5, self.screen_h * 0.8
    
    for i = count, 1, -1 do
        local n = notifs[i]
        if tick > n.expire then
            table_remove(notifs, i)
        else
            local alpha = math_min(255, (n.expire - tick) * 2)
            local tw, th = draw_GetTextSize(n.text)
            local htw = tw * 0.5
            draw_Color(0, 0, 0, alpha * 0.7)
            draw_FilledRect(cx - htw - 10, yo - 5, cx + htw + 10, yo + th + 5)
            draw_Color(n.r, n.g, n.b, alpha)
            draw_TextShadow(cx - htw, yo, n.text)
            yo = yo + th + 15
        end
    end
end

function GH:parseStringifiedTable(s)
    local nm = {}
    if not s or s == "" then return nm end
    
    for l in string_gmatch(s, "([^\n]+)") do
        local p, idx = {}, 0
        for sg in string_gmatch(l, "([^,]+)") do
            idx = idx + 1
            p[idx] = sg
        end
        if idx >= 10 then
            local k = self:canonMapName(p[1])
            if k ~= "" then
                nm[k] = nm[k] or {}
                local position = p[3]
                local launch = p[4]
                local ax = tonumber(p[9]) or 0
                local ay = tonumber(p[10]) or 0
                
                local axn, ayn = self:normalizeAngles(ax, ay)
                local fx, fy, fz = self:anglesToForward(axn, ayn)
                
                nm[k][#nm[k] + 1] = {
                    name = p[2],
                    position = position,
                    launch = launch,
                    nade = p[5],
                    pos = {x = tonumber(p[6]) or 0, y = tonumber(p[7]) or 0, z = tonumber(p[8]) or 0},
                    ax = ax,
                    ay = ay,
                    is_crouch = string_find(position, "crouch") ~= nil,
                    fx = fx, fy = fy, fz = fz,
                    pos_txt = "[" .. position .. "]",
                    launch_txt = "[" .. launch .. "]"
                }
            end
        end
    end
    return nm
end

function GH:convertTableToDataString(o)
    if not o then return "" end
    local out, idx = {}, 0
    for mn, m in pairs(o) do
        if type(m) == "table" then
            for i = 1, #m do
                local t = m[i]
                idx = idx + 1
                out[idx] = table_concat({
                    mn, t.name or "", t.position or "stand", t.launch or "left", t.nade or "auto",
                    tostring(t.pos and t.pos.x or 0), tostring(t.pos and t.pos.y or 0),
                    tostring(t.pos and t.pos.z or 0), tostring(t.ax or 0), tostring(t.ay or 0)
                }, ",")
            end
        end
    end
    return idx > 0 and (table_concat(out, "\n") .. "\n") or ""
end

function GH:loadData()
    if not self.has_file_open then return end
    local ok, f = pcall(file.Open, self.SAVE_FILE, "r")
    if not ok or not f then return end
    local okr, d = pcall(function() return f:Read() end)
    pcall(function() f:Close() end)
    if okr and d and d ~= "" then
        self.maps = self:parseStringifiedTable(d)
        self.local_data_hash = self:simpleHash(d)
        self:addNotification("[GH] Data loaded", 0, 255, 100)
    end
end

function GH:saveData()
    if not self.has_file_write then return end
    local ok = pcall(file.Write, self.SAVE_FILE, self:convertTableToDataString(self.maps))
    self:addNotification(ok and "[GH] Saved" or "[GH] Error", ok and 0 or 255, ok and 255 or 100, 100)
end

function GH:downloadGrenadeData(cb)
    self:addNotification("[GH] Downloading...", 0, 200, 255)
    if not self.has_http or not self.has_file_write then
        if cb then cb(false) end
        return
    end
    pcall(function()
        http.Get(self.DATA_URL, function(b)
            if b and b ~= "" then
                local ok = pcall(file.Write, self.SAVE_FILE, b)
                if ok then
                    self.local_data_hash = self:simpleHash(b)
                    self:addNotification("[GH] Done!", 0, 255, 100)
                    self:loadData()
                    if cb then cb(true) end
                else
                    self:addNotification("[GH] Write failed", 255, 100, 100)
                    if cb then cb(false) end
                end
            else
                self:addNotification("[GH] Download failed", 255, 100, 100)
                if cb then cb(false) end
            end
        end)
    end)
end

function GH:downloadScript(cb)
    self:addNotification("[GH] Updating...", 0, 200, 255)
    if not self.has_http or not self.has_file_write then
        if cb then cb(false) end
        return
    end
    pcall(function()
        http.Get(self.SCRIPT_URL, function(b)
            if b and b ~= "" then
                local ok = pcall(file.Write, self.SCRIPT_NAME, b)
                if ok then
                    self.local_script_hash = self:simpleHash(b)
                    self:addNotification("[GH] Reload required", 255, 200, 0)
                    if cb then cb(true) end
                else
                    self:addNotification("[GH] Write failed", 255, 100, 100)
                    if cb then cb(false) end
                end
            else
                self:addNotification("[GH] Download failed", 255, 100, 100)
                if cb then cb(false) end
            end
        end)
    end)
end

function GH:createUpdateWindow()
    if self.update_window then
        self.update_window:Remove()
        self.update_window = nil
    end
    self.update_window = gui.Window("gh_update_window", "Grenade Helper - Updates", 300, 200, 180, 360)
    if not self.update_window then
        self:addNotification("[GH] Failed to create window", 255, 100, 100)
        return
    end
    local cg = gui.Groupbox(self.update_window, "Update Status", 16, 16, 150, 0)
    gui.Text(cg, "Update check complete!")
    for _, u in ipairs(self.updates_found) do
        gui.Text(cg, " ")
        gui.Text(cg, "--------------------------")
        gui.Text(cg, " ")
        gui.Text(cg, u.name)
        gui.Text(cg, " ")
        gui.Text(cg, "Status: " .. u.status)
        gui.Text(cg, " ")
        if u.needs_update then
            if u.type == "data" then
                gui.Button(cg, "Download Data", function()
                    self:downloadGrenadeData(function(success)
                        if success and self.update_window then
                            u.status = "Downloaded!"
                            u.needs_update = false
                            self.update_window:Remove()
                            self.update_window = nil
                            self:createUpdateWindow()
                        end
                    end)
                end)
                gui.Text(cg, "(Reload Required)")
            elseif u.type == "script" then
                gui.Button(cg, "Download Script", function()
                    self:downloadScript(function(success)
                        if success and self.update_window then
                            u.status = "Downloaded!"
                            u.needs_update = false
                            self.update_window:Remove()
                            self.update_window = nil
                            self:createUpdateWindow()
                        end
                    end)
                end)
                gui.Text(cg, "(Reload Required)")
            end
        end
    end
    gui.Text(cg, "")
    gui.Text(cg, "--------------------------")
    gui.Text(cg, " ")
    gui.Button(cg, "Close Window", function()
        if self.update_window then
            self.update_window:Remove()
            self.update_window = nil
        end
    end)
end

function GH:finishUpdateCheck()
    local has_updates = false
    for _, u in ipairs(self.updates_found) do
        if u.needs_update then
            has_updates = true
            break
        end
    end
    self:addNotification(has_updates and "[GH] Updates available!" or "[GH] Everything up to date!", 0, 255, 100)
    self:createUpdateWindow()
end

function GH:checkForUpdates()
    if self.checking_update then
        self:addNotification("[GH] Already checking...", 255, 200, 0)
        return
    end
    if not self.has_http then
        self:addNotification("[GH] HTTP disabled", 255, 200, 0)
        return
    end
    self.checking_update = true
    self.updates_found = {}
    self:addNotification("[GH] Checking for updates...", 0, 200, 255)
    local remaining = 2
    local function done()
        remaining = remaining - 1
        if remaining == 0 then
            self.checking_update = false
            self:finishUpdateCheck()
        end
    end
    local ok1 = pcall(function()
        http.Get(self.DATA_URL, function(b)
            if b and b ~= "" then
                self.remote_data_hash = self:simpleHash(b)
                if self.local_data_hash == "" and self.has_file_open then
                    local ok_f, f = pcall(file.Open, self.SAVE_FILE, "r")
                    if ok_f and f then
                        local ok_r, ld = pcall(function() return f:Read() end)
                        pcall(function() f:Close() end)
                        if ok_r and ld then
                            self.local_data_hash = self:simpleHash(ld)
                        end
                    end
                end
                local needs = self.remote_data_hash ~= self.local_data_hash
                self.updates_found[#self.updates_found + 1] = {
                    name = "Grenade Positions Data",
                    status = needs and "Update available" or "Up to date",
                    type = "data",
                    needs_update = needs
                }
            else
                self.updates_found[#self.updates_found + 1] = {
                    name = "Grenade Positions Data",
                    status = "Check failed",
                    type = "data",
                    needs_update = false
                }
            end
            done()
        end)
    end)
    if not ok1 then
        self.updates_found[#self.updates_found + 1] = {
            name = "Grenade Positions Data",
            status = "Check failed (HTTP error)",
            type = "data",
            needs_update = false
        }
        done()
    end
    local ok2 = pcall(function()
        http.Get(self.SCRIPT_URL, function(b)
            if b and b ~= "" then
                self.remote_script_hash = self:simpleHash(b)
                if self.local_script_hash == "" and self.has_file_open then
                    local ok_f, f = pcall(file.Open, self.SCRIPT_NAME, "r")
                    if ok_f and f then
                        local ok_r, ls = pcall(function() return f:Read() end)
                        pcall(function() f:Close() end)
                        if ok_r and ls then
                            self.local_script_hash = self:simpleHash(ls)
                        end
                    end
                end
                local needs = self.remote_script_hash ~= self.local_script_hash
                self.updates_found[#self.updates_found + 1] = {
                    name = "Grenade Helper Script",
                    status = needs and "Update available" or "Up to date",
                    type = "script",
                    needs_update = needs
                }
            else
                self.updates_found[#self.updates_found + 1] = {
                    name = "Grenade Helper Script",
                    status = "Check failed",
                    type = "script",
                    needs_update = false
                }
            end
            done()
        end)
    end)
    if not ok2 then
        self.updates_found[#self.updates_found + 1] = {
            name = "Grenade Helper Script",
            status = "Check failed (HTTP error)",
            type = "script",
            needs_update = false
        }
        done()
    end
end

function GH:getActiveThrows(m, mx, my, mz, nn, md)
    if not m then return nil, false end
    local l, ir = {}, {}
    local md_sq, tr_sq = md * md, self.THROW_RADIUS_SQ
    for i = 1, #m do
        local t = m[i]
        local tn = t.nade
        if tn == nn or tn == "auto" then
            local tp = t.pos
            local d_sq = self:dist3DSq(mx, my, mz, tp.x, tp.y, tp.z)
            if d_sq <= md_sq then
                t.distance = math_sqrt(d_sq)
                if d_sq < tr_sq then
                    ir[#ir + 1] = t
                else
                    l[#l + 1] = t
                end
            end
        end
    end
    local use_ir = #ir > 0
    return use_ir and ir or l, use_ir
end

function GH:getClosestThrow(m, mx, my, mz, nn, md)
    if not m or #m == 0 then return nil end
    local md_sq = md * md
    local best, best_sq = nil, 1e20
    for i = 1, #m do
        local t = m[i]
        if t.nade == nn or t.nade == "auto" then
            local tp = t.pos
            local d_sq = self:dist3DSq(mx, my, mz, tp.x, tp.y, tp.z)
            if d_sq < best_sq and d_sq <= md_sq then
                best, best_sq = t, d_sq
            end
        end
    end
    return best
end

function GH:moveToPosition(c, ox, oy, tx, ty, d)
    local dx, dy = tx - ox, ty - oy
    if dx == 0 and dy == 0 then return end
    local va = c:GetViewAngles()
    local yd = (math_atan2(dy, dx) * 180 / self.PI - va.y) * self.DEG_TO_RAD
    if yd > self.PI then yd = yd - self.TWO_PI
    elseif yd < -self.PI then yd = yd + self.TWO_PI end
    c:SetForwardMove(math_cos(yd))
    c:SetSideMove(math_sin(yd))
    local bt = bit_band(c:GetButtons() or 0, self.MOVE_MASK)
    if d > 45 or globals_TickCount() % 3 == 0 then
        bt = bit_bor(bt, self.FORWARD_LEFT)
    else
        c:SetForwardMove(0)
        c:SetSideMove(0)
    end
    c:SetButtons(bt)
end

function GH:walkbotNavigate(c, me)
    local wb = self.walkbot
    local mx, my, mz = self:getOriginXYZ(me)
    local d_sq = self:dist3DSq(mx, my, mz, wb.target_x, wb.target_y, wb.target_z)
    if d_sq < self.WALKBOT_STOP_DISTANCE_SQ then
        c:SetForwardMove(0)
        c:SetSideMove(0)
        self:addNotification("[GH] Arrived!", 0, 255, 100)
        return true
    end
    if globals_TickCount() - wb.start_time > self.WALKBOT_TIMEOUT then
        self:addNotification("[GH] Timeout", 255, 100, 0)
        return true
    end
    self:moveToPosition(c, mx, my, wb.target_x, wb.target_y, math_sqrt(d_sq))
    return false
end

function GH:startWalkbot(me)
    if not self.current_map or not self.maps[self.current_map] then
        self:addNotification("[GH] No throws", 255, 100, 100)
        return
    end
    local wn = self:getActiveGrenadeName()
    if not wn then
        self:addNotification("[GH] No grenade", 255, 100, 0)
        return
    end
    local mx, my, mz = self:getOriginXYZ(me)
    local md = self.ui.VISUALS_DISTANCE:GetValue()
    local b = self:getClosestThrow(self.maps[self.current_map], mx, my, mz, wn, md)
    if not b then
        self:addNotification("[GH] None found", 255, 100, 100)
        return
    end
    local wb = self.walkbot
    wb.target_x, wb.target_y, wb.target_z = b.pos.x, b.pos.y, b.pos.z
    wb.target_nade = wn
    wb.active = true
    wb.start_time = globals_TickCount()
    self:addNotification("[GH] -> " .. (b.name or "pos"), 0, 255, 255)
end

function GH:stopWalkbot()
    self.walkbot.active = false
    self.walkbot.target_nade = nil
end

function GH:doAdd(cmd)
    local me = entities_GetLocalPlayer()
    if not me or (me.IsAlive and not me:IsAlive()) then return end
    if self:getVelocity(me) > 0 then
        self:addNotification("[GH] Stand still", 255, 100, 0)
        return
    end
    if not self.current_map then return end
    self.maps[self.current_map] = self.maps[self.current_map] or {}
    local name = tostring(self.ui.NAME_EB:GetValue() or "")
    name = string_gsub(string_gsub(name, "^%s+", ""), "%s+$", "")
    if name == "" then
        self:addNotification("[GH] Name empty", 255, 100, 100)
        return
    end
    local mx, my, mz = self:getOriginXYZ(me)
    local ax, ay = 0, 0
    if cmd and cmd.GetViewAngles then
        local va = cmd:GetViewAngles()
        if va then ax, ay = self:toNum2(va) end
    end
    
    local position = self.POSITION_TYPES[self.ui.POSITION_CB:GetValue() + 1] or "stand"
    local launch = self.LAUNCH_TYPES[self.ui.LAUNCH_CB:GetValue() + 1] or "left"
    
    local axn, ayn = self:normalizeAngles(ax, ay)
    local fx, fy, fz = self:anglesToForward(axn, ayn)
    
    local list = self.maps[self.current_map]
    list[#list + 1] = {
        name = name,
        position = position,
        launch = launch,
        nade = self:getActiveGrenadeName() or "auto",
        pos = {x = mx, y = my, z = mz},
        ax = ax, ay = ay,
        is_crouch = string_find(position, "crouch") ~= nil,
        fx = fx, fy = fy, fz = fz,
        pos_txt = "[" .. position .. "]",
        launch_txt = "[" .. launch .. "]"
    }
    self:saveData()
end

function GH:doDel(me)
    if not self.current_map or not self.maps[self.current_map] then return end
    local mx, my, mz = self:getOriginXYZ(me)
    local wn = self:getActiveGrenadeName() or "auto"
    local md = self.ui.VISUALS_DISTANCE:GetValue()
    local best = self:getClosestThrow(self.maps[self.current_map], mx, my, mz, wn, md)
    if not best then return end
    local list = self.maps[self.current_map]
    for i = #list, 1, -1 do
        if list[i] == best then
            table_remove(list, i)
            self:saveData()
            self:addNotification("[GH] Deleted: " .. (best.name or "?"), 255, 150, 0)
            return
        end
    end
end

function GH:updateColorCache()
    local tick = globals_TickCount()
    local c = self.cache
    if tick - c.color_tick < 64 then return end
    c.color_tick = tick
    local colors, u = c.colors, self.ui
    colors.nr, colors.ng, colors.nb, colors.na = u.CP_TEXT_NAME:GetValue()
    colors.pr, colors.pg, colors.pb, colors.pa = u.CP_TEXT_POS:GetValue()
    colors.lr, colors.lg, colors.lb, colors.la = u.CP_TEXT_LAUNCH:GetValue()
    colors.lnr, colors.lng, colors.lnb, colors.lna = u.CP_LINE:GetValue()
    colors.br, colors.bg, colors.bb, colors.ba = u.CP_BOX:GetValue()
    colors.fr, colors.fg, colors.fb, colors.fa = u.CP_FINAL:GetValue()
end

function GH:showNadeThrows()
    local me = entities_GetLocalPlayer()
    if not me then return end
    local weapon_name = self:getActiveGrenadeName()
    if not weapon_name then return end
    local map_throws = self.maps[self.current_map]
    if not map_throws then return end
    
    local mx, my, mz = self:getOriginXYZ(me)
    local max_dist = self.ui.VISUALS_DISTANCE:GetValue()
    local list, within = self:getActiveThrows(map_throws, mx, my, mz, weapon_name, max_dist)
    if not list or #list == 0 then return end
    
    self:updateColorCache()
    local c = self.cache.colors
    local hsw, hsh = self.screen_w * 0.5, self.screen_h * 0.5
    
    local MARKER_DIST = self.DRAW_MARKER_DISTANCE
    local half = self.THROW_RADIUS_HALF
    local inv_max = 1 / max_dist
    
    local nr, ng, nb, na = c.nr, c.ng, c.nb, c.na
    local pr, pg, pb, pa = c.pr, c.pg, c.pb, c.pa
    local lr, lg, lb, la = c.lr, c.lg, c.lb, c.la
    local lnr, lng, lnb, lna = c.lnr, c.lng, c.lnb, c.lna
    local br, bg, bb = c.br, c.bg, c.bb
    local fr, fg, fb, fa = c.fr, c.fg, c.fb, c.fa
    
    for i = 1, #list do
        local t = list[i]
        local tp = t.pos
        local px, py, pz = tp.x, tp.y, tp.z
        
        local zoff = t.is_crouch and 46 or 64
        local fx, fy, fz = t.fx, t.fy, t.fz
        
        local s1x, s1y = client_WorldToScreen(Vector3(px + fx * 10, py + fy * 10, pz))
        
        if within then
            local tx = px + fx * MARKER_DIST
            local ty = py + fy * MARKER_DIST
            local tz = pz + zoff + fz * MARKER_DIST
            local dx, dy = client_WorldToScreen(Vector3(tx, ty, tz))
            if dx and dy then
                draw_Color(fr, fg, fb, fa)
                draw_OutlinedRect(dx - 8, dy - 8, dx + 8, dy + 8)
                draw_Color(lnr, lng, lnb, lna)
                draw_Line(dx, dy, hsw, hsh)
                
                local tname = t.name
                if tname then
                    local tw, th = draw_GetTextSize(tname)
                    draw_Color(nr, ng, nb, na)
                    draw_TextShadow(dx - tw * 0.5, dy - th - 10, tname)
                end
                
                local ptw, pth = draw_GetTextSize(t.pos_txt)
                draw_Color(pr, pg, pb, pa)
                draw_TextShadow(dx - ptw * 0.5, dy + 12, t.pos_txt)
                
                local ltw = draw_GetTextSize(t.launch_txt)
                draw_Color(lr, lg, lb, la)
                draw_TextShadow(dx - ltw * 0.5, dy + 14 + pth, t.launch_txt)
            end
        end
        
        local cx, cy = client_WorldToScreen(Vector3(px, py, pz))
        if not cx or not cy then goto continue end
        
        local ulx, uly = client_WorldToScreen(Vector3(px - half, py - half, pz))
        local blx, bly = client_WorldToScreen(Vector3(px - half, py + half, pz))
        local urx, ury = client_WorldToScreen(Vector3(px + half, py - half, pz))
        local brx, bry = client_WorldToScreen(Vector3(px + half, py + half, pz))
        
        local alpha = (1 - (t.distance or 0) * inv_max) * 255
        alpha = alpha < 50 and 50 or (alpha > 255 and 255 or alpha)
        draw_Color(br, bg, bb, alpha)
        
        if ulx and blx and urx and brx then
            draw_Line(ulx, uly, blx, bly)
            draw_Line(blx, bly, brx, bry)
            draw_Line(brx, bry, urx, ury)
            draw_Line(urx, ury, ulx, uly)
        else
            draw_FilledRect(cx - 3, cy - 3, cx + 3, cy + 3)
        end
        
        local tname = t.name
        if tname then
            local tw, th = draw_GetTextSize(tname)
            draw_Color(nr, ng, nb, alpha)
            draw_TextShadow(cx - tw * 0.5, cy - th - 4, tname)
        end
        
        if s1x and s1y then
            draw_Color(lnr, lng, lnb, lna)
            draw_Line(cx, cy, s1x, s1y)
        end
        
        ::continue::
    end
end

function GH:onGameEvent(event)
    if not self.ui.ENABLED:GetValue() then return end
    if not event or not event.GetName then return end
    local name = event:GetName()
    if name == "round_start" or name == "round_end" or name == "player_death" then
        self.jumpthrow_stage = 0
        self:stopWalkbot()
    end
end

function GH:onDraw()
    self.screen_w, self.screen_h = draw_GetScreenSize()
    if not self.ui.ENABLED:GetValue() then return end
    local map = engine_GetMapName and engine_GetMapName()
    if not map or map == "" then return end
    local map_key = self:canonMapName(map)
    if map_key == "" then return end
    if self.current_map ~= map_key then
        self.current_map = map_key
        self:loadData()
    end
    self.maps[self.current_map] = self.maps[self.current_map] or {}
    self:showNadeThrows()
    self:drawNotifications()
    if self.walkbot.active then
        local me = entities_GetLocalPlayer()
        if me then
            local mx, my, mz = self:getOriginXYZ(me)
            local wb = self.walkbot
            local d = self:dist3D(mx, my, mz, wb.target_x, wb.target_y, wb.target_z)
            local cx = self.screen_w * 0.5
            local by = self.screen_h - 120
            local t1, t2, t3 = "[GH] WALKING TO POSITION", string_format("Distance: %.1f units", d), "Press ALT to cancel"
            local w1 = draw_GetTextSize(t1)
            local w2 = draw_GetTextSize(t2)
            local w3 = draw_GetTextSize(t3)
            draw_Color(0, 0, 0, 180)
            draw_FilledRect(cx - 120, by - 5, cx + 120, by + 55)
            draw_Color(0, 255, 255, 255)
            draw_TextShadow(cx - w1 * 0.5, by, t1)
            draw_Color(255, 255, 255, 255)
            draw_TextShadow(cx - w2 * 0.5, by + 18, t2)
            draw_Color(200, 200, 200, 200)
            draw_TextShadow(cx - w3 * 0.5, by + 36, t3)
        end
    end
end

function GH:onMove(cmd)
    if not self.ui.ENABLED:GetValue() or not cmd then return end
    local me = entities_GetLocalPlayer()
    if not me or (me.IsAlive and not me:IsAlive()) then
        self:stopWalkbot()
        return
    end
    if not self.current_map or not self.maps[self.current_map] then return end
    local tick = globals_TickCount()
    if self.last_action > tick then self.last_action = tick end
    
    local wb = self.walkbot
    if wb.active then
        if self:getActiveGrenadeName() ~= wb.target_nade then
            self:stopWalkbot()
            self:addNotification("[GH] Wrong nade", 255, 150, 0)
        elseif self:walkbotNavigate(cmd, me) then
            self:stopWalkbot()
        end
    end
    
    local jt_key = self.ui.JUMPTHROW_KB:GetValue()
    if jt_key ~= 0 then
        if input_IsButtonPressed(jt_key) and self.jumpthrow_stage == 0 then
            self.jumpthrow_stage = 1
            self.jumpthrow_tick = tick
        end
        if self.jumpthrow_stage > 0 then
            local diff = tick - self.jumpthrow_tick
            if self.jumpthrow_stage == 1 then
                cmd:SetButtons(bit_bor(cmd:GetButtons(), 2))
                if diff >= 1 then self.jumpthrow_stage = 2 end
            elseif self.jumpthrow_stage == 2 then
                cmd:SetButtons(bit_band(cmd:GetButtons(), bit_bnot(2049)))
                if diff >= 2 then self.jumpthrow_stage = 0 end
            end
        end
    end
    
    if not self.ui.ENABLE_KB:GetValue() then return end
    local u = self.ui
    local add_key, del_key, wb_key = u.SAVE_KB:GetValue(), u.DEL_KB:GetValue(), u.WALKBOT_KB:GetValue()
    if add_key == 0 and del_key == 0 and wb_key == 0 then return end
    local cd_ok = tick - self.last_action > self.ACTION_COOLDOWN
    
    if add_key ~= 0 and input_IsButtonDown(add_key) and cd_ok then
        self.last_action = tick
        self:doAdd(cmd)
    end
    if del_key ~= 0 and input_IsButtonDown(del_key) and cd_ok then
        self.last_action = tick
        self:doDel(me)
    end
    if wb_key ~= 0 and input_IsButtonDown(wb_key) and cd_ok then
        self.last_action = tick
        if wb.active then
            self:stopWalkbot()
            self:addNotification("[GH] Cancelled", 255, 150, 0)
        else
            self:startWalkbot(me)
        end
    end
end

function GH:initUI()
    local ref = gui.Reference("VISUALS", "Local")
    local gb = gui.Groupbox(ref, "Grenade Helper", 15, 0, 352, 0)
    local u = self.ui
    u.ENABLED = gui.Checkbox(gb, "gh.on", "Enable", true)
    u.NAME_EB = gui.Editbox(gb, "gh.name", "Name")
    u.POSITION_CB = gui.Combobox(gb, "gh.pos", "Position", unpack(self.POSITION_TYPES))
    u.LAUNCH_CB = gui.Combobox(gb, "gh.launch", "Launch", unpack(self.LAUNCH_TYPES))
    u.ENABLE_KB = gui.Checkbox(gb, "gh.kb", "Keybinds", true)
    u.SAVE_KB = gui.Keybox(gb, "gh.k.save", "Save", 97)
    u.DEL_KB = gui.Keybox(gb, "gh.k.del", "Delete", 98)
    u.JUMPTHROW_KB = gui.Keybox(gb, "gh.k.jt", "Jump Throw", 70)
    u.WALKBOT_KB = gui.Keybox(gb, "gh.k.wb", "Walk To", 18)
    u.VISUALS_DISTANCE = gui.Slider(gb, "gh.dist", "Distance", 800, 1, 9999)
    gui.Text(gb, "")
    u.CP_TEXT_NAME = gui.ColorPicker(gb, "gh.c.name", "Name Color", 255, 255, 0, 255)
    u.CP_TEXT_POS = gui.ColorPicker(gb, "gh.c.pos", "Position", 150, 255, 150, 200)
    u.CP_TEXT_LAUNCH = gui.ColorPicker(gb, "gh.c.launch", "Launch", 255, 150, 150, 200)
    u.CP_LINE = gui.ColorPicker(gb, "gh.c.line", "Line", 0, 255, 255, 220)
    u.CP_BOX = gui.ColorPicker(gb, "gh.c.box", "Box", 0, 0, 0, 255)
    u.CP_FINAL = gui.ColorPicker(gb, "gh.c.active", "Active", 0, 255, 100, 255)
    gui.Button(gb, "Check Updates", function() self:checkForUpdates() end)
end

function GH:init()
    self:cacheAPI()
    if self.has_file_open then
        local exists = false
        if self.has_file_enum then
            pcall(function()
                file.Enumerate(function(fn)
                    if fn == self.SAVE_FILE then exists = true end
                end)
            end)
        end
        if not exists and self.has_http then
            pcall(function()
                local b = http.Get(self.DATA_URL)
                if b and b ~= "" and self.has_file_write then
                    file.Write(self.SAVE_FILE, b)
                end
            end)
        end
        local ok, f = pcall(file.Open, self.SAVE_FILE, "r")
        if ok and f then
            local okr, d = pcall(function() return f:Read() end)
            pcall(function() f:Close() end)
            if okr and d and d ~= "" then
                self.maps = self:parseStringifiedTable(d)
                self.local_data_hash = self:simpleHash(d)
            end
        end
        local oks, sf = pcall(file.Open, self.SCRIPT_NAME, "r")
        if oks and sf then
            local oksr, sd = pcall(function() return sf:Read() end)
            pcall(function() sf:Close() end)
            if oksr and sd then self.local_script_hash = self:simpleHash(sd) end
        end
    end
    self:initUI()
    client_AllowListener("round_start")
    client_AllowListener("round_end")
    client_AllowListener("player_death")
    callbacks.Register("FireGameEvent", "GH_E", function(e) GH:onGameEvent(e) end)
    callbacks.Register("CreateMove", "GH_M", function(c) GH:onMove(c) end)
    callbacks.Register("Draw", "GH_D", function() GH:onDraw() end)
    self:addNotification("[GH] v" .. self.VERSION .. " Loaded!", 0, 255, 100)
    self:addNotification("Num1=Save Num2=Del F=JT ALT=Walk", 200, 200, 255)
end

GH:init()
