local MOVE_MAX=1.0

local BODY_BASE_PRED=0.010
local BODY_LATENCY_SCALE=0.35
local BODY_MAX_PRED=0.035
local BODY_DEADZONE=0.24
local BODY_GAIN=30.0
local BODY_BRAKE_MULT=1.55
local BODY_QUICKSTOP_GAIN=0.020
local BODY_AXIS_SWITCH_RATIO=1.20

local LATENCY_DEFAULT_MS=18

local VEL_FILTER_ALPHA=0.34
local ACCEL_FILTER_ALPHA=0.22
local MAX_ACCEL_2D=320.0

local HEAD_XY_RADIUS=26.0
local HEAD_BASE_PRED=0.014
local HEAD_LATENCY_SCALE=0.12
local HEAD_MAX_PRED=0.028
local HEAD_GAP_DEADZONE=0.04
local HEAD_TRACK_MULT=0.30
local HEAD_BRAKE_MULT=2.0
local HEAD_MAX_MOVE=1.0

local HEAD_HEIGHT_STAND=64.0
local HEAD_HEIGHT_CROUCH=46.0
local HEAD_Z_TOLERANCE=12.0

local HEAD_PITCH_ENABLE=true
local HEAD_YAW_ENABLE=true
local HEAD_JUMP_DZVEL=30.0
local HEAD_DUCK_DZVEL=-30.0

local RH=22
local Y0=6

local wnd=gui.Window("bb52_wnd","Blockbot",100,100,250,242)

local function row(ctrl,n)
    ctrl:SetPosY(Y0+n*RH)
    ctrl:SetPosX(8)
    return ctrl
end

local on=row(gui.Checkbox(wnd,"bb52_on","Enable",false),0)
local dot=row(gui.Checkbox(wnd,"bb52_dot","Target Dot",true),1)
local dotc=row(gui.ColorPicker(wnd,"bb52_dotc","Dot Color",255,80,30,255),2)
local grid=row(gui.Checkbox(wnd,"bb52_gr","3D Grid",true),3)
local gridc=row(gui.ColorPicker(wnd,"bb52_grc","Grid Color",0,180,255,255),4)
local latency=row(gui.Slider(wnd,"bb52_lat","Latency Comp ms",LATENCY_DEFAULT_MS,0,80,1),5)
local hudx=row(gui.Slider(wnd,"bb52_sx","HUD X",16,0,3840,1),6)
local hudy=row(gui.Slider(wnd,"bb52_sy","HUD Y",900,0,2160,1),7)

local font=draw.CreateFont("Verdana",13,400)
local menu=gui.Reference("MENU")

local target=nil
local mode="OFF"
local axis=nil

local skip_classes={
    ["C_CSGO_PreviewPlayer"]=true,
    ["CCSPlayerController"]=true,
    ["C_CSGO_TeamPreviewPlayer"]=true,
}

local vel_cache={}
local motion_cache={}

local function clamp(v,a,b)
    if v<a then return a end
    if v>b then return b end
    return v
end

local function valid_vec(v)
    return v and type(v.x)=="number" and type(v.y)=="number" and type(v.z)=="number"
end

local function norm_yaw(y)
    while y>180 do y=y-360 end
    while y<-180 do y=y+360 end
    return y
end

local function norm_pitch(p)
    if p>89 then p=89 end
    if p<-89 then p=-89 end
    return p
end

local function team(ent)
    local ok,t=pcall(function() return ent:GetPropInt("m_iTeamNum") end)
    if ok and t then return t end
    ok,t=pcall(function() return ent:GetTeamNumber() end)
    if ok and t then return t end
    return 0
end

local function classname(ent)
    if not ent then return "nil" end
    local ok,v=pcall(function() return ent:GetClass() end)
    if ok and v and v~="" then return tostring(v) end
    ok,v=pcall(function() return ent:GetClassname() end)
    if ok and v and v~="" then return tostring(v) end
    ok,v=pcall(function() return ent:GetClientClass() end)
    if ok and v then return tostring(v) end
    ok,v=pcall(function() return ent:GetName() end)
    if ok and v and v~="" then return tostring(v) end
    return "unknown"
end

local function ent_name(ent)
    if not ent then return "none" end
    local ok,idx=pcall(function() return ent:GetIndex() end)
    if ok and idx then
        local ok2,n=pcall(function() return client.GetPlayerNameByIndex(idx) end)
        if ok2 and n and n~="" then return n end
    end
    ok,n=pcall(function() return ent:GetName() end)
    if ok and n and n~="" then return tostring(n) end
    return "unknown"
end

local function valid_pawn(ent)
    if not ent then return false end
    if skip_classes[classname(ent)] then return false end
    local ok,alive=pcall(function() return ent:IsAlive() end)
    if not (ok and alive) then return false end
    ok,pos=pcall(function() return ent:GetAbsOrigin() end)
    if not (ok and valid_vec(pos)) then return false end
    if pos.x==0 and pos.y==0 and pos.z==0 then return false end
    return true
end

local function raw_vel(ent)
    local ok,idx=pcall(function() return ent:GetIndex() end)
    if not ok or not idx then return {x=0,y=0,z=0} end

    ok,pos=pcall(function() return ent:GetAbsOrigin() end)
    if not ok or not valid_vec(pos) then return {x=0,y=0,z=0} end

    local now=common.Time()
    local c=vel_cache[idx]

    if c and (now-c.t)>0.001 and (now-c.t)<0.5 then
        vel_cache[idx]={x=pos.x,y=pos.y,z=pos.z,t=now}
        local dt=now-c.t
        return {
            x=(pos.x-c.x)/dt,
            y=(pos.y-c.y)/dt,
            z=(pos.z-c.z)/dt
        }
    end

    vel_cache[idx]={x=pos.x,y=pos.y,z=pos.z,t=now}
    return {x=0,y=0,z=0}
end

local function motion(ent)
    local ok,idx=pcall(function() return ent:GetIndex() end)
    if not ok or not idx then
        return {vx=0,vy=0,vz=0,ax=0,ay=0,az=0}
    end

    local rv=raw_vel(ent)
    local now=common.Time()
    local c=motion_cache[idx]

    if not c then
        motion_cache[idx]={
            vx=rv.x,vy=rv.y,vz=rv.z,
            ax=0,ay=0,az=0,
            t=now
        }
        return {vx=rv.x,vy=rv.y,vz=rv.z,ax=0,ay=0,az=0}
    end

    local dt=now-c.t
    if dt<=0.001 or dt>0.25 then
        motion_cache[idx]={
            vx=rv.x,vy=rv.y,vz=rv.z,
            ax=0,ay=0,az=0,
            t=now
        }
        return {vx=rv.x,vy=rv.y,vz=rv.z,ax=0,ay=0,az=0}
    end

    local fv_x=c.vx+(rv.x-c.vx)*VEL_FILTER_ALPHA
    local fv_y=c.vy+(rv.y-c.vy)*VEL_FILTER_ALPHA
    local fv_z=c.vz+(rv.z-c.vz)*VEL_FILTER_ALPHA

    local ra_x=(fv_x-c.vx)/dt
    local ra_y=(fv_y-c.vy)/dt
    local ra_z=(fv_z-c.vz)/dt

    local fa_x=c.ax+(ra_x-c.ax)*ACCEL_FILTER_ALPHA
    local fa_y=c.ay+(ra_y-c.ay)*ACCEL_FILTER_ALPHA
    local fa_z=c.az+(ra_z-c.az)*ACCEL_FILTER_ALPHA

    fa_x=clamp(fa_x,-MAX_ACCEL_2D,MAX_ACCEL_2D)
    fa_y=clamp(fa_y,-MAX_ACCEL_2D,MAX_ACCEL_2D)

    motion_cache[idx]={
        vx=fv_x,vy=fv_y,vz=fv_z,
        ax=fa_x,ay=fa_y,az=fa_z,
        t=now
    }

    return {vx=fv_x,vy=fv_y,vz=fv_z,ax=fa_x,ay=fa_y,az=fa_z}
end

local function eye_angles(ent)
    if not ent then return nil end
    local ok,ang=pcall(function() return ent:GetEyeAngles() end)
    if ok and ang then
        local p=ang.x or ang.pitch
        local y=ang.y or ang.yaw
        local r=ang.z or ang.roll or 0
        if type(p)=="number" and type(y)=="number" then
            return {x=p,y=y,z=r}
        end
    end
    return nil
end

local function duck_amount(ent)
    if not ent then return 0.0 end
    local ok,v=pcall(function() return ent:GetPropFloat("m_flDuckAmount") end)
    if ok and type(v)=="number" then return clamp(v,0.0,1.0) end
    ok,v=pcall(function() return ent:GetPropBool("m_bDucked") end)
    if ok and v~=nil then return v and 1.0 or 0.0 end
    return 0.0
end

local function target_head_z(ent,oz)
    local d=duck_amount(ent)
    local h=HEAD_HEIGHT_STAND+(HEAD_HEIGHT_CROUCH-HEAD_HEIGHT_STAND)*d
    return oz+h
end

local function local_pawn()
    local ok,p=pcall(function() return entities.GetLocalPawn() end)
    if ok and p and valid_pawn(p) then return p end
    local ctrl=entities.GetLocalPlayer()
    if ctrl then
        if valid_pawn(ctrl) then return ctrl end
        local ok2,h=pcall(function() return ctrl:GetPropEntity("m_hPawn") end)
        if ok2 and h and valid_pawn(h) then return h end
    end
    return nil
end

local function cmd_angles(cmd,pawn)
    local ok,ang=pcall(function() return cmd.viewangles end)
    if ok and ang then
        local p=ang.x or ang.pitch
        local y=ang.y or ang.yaw
        local r=ang.z or ang.roll or 0
        if type(p)=="number" and type(y)=="number" then
            return {x=p,y=y,z=r}
        end
    end

    ok,ang=pcall(function() return cmd:GetViewAngles() end)
    if ok and ang then
        local p=ang.x or ang.pitch
        local y=ang.y or ang.yaw
        local r=ang.z or ang.roll or 0
        if type(p)=="number" and type(y)=="number" then
            return {x=p,y=y,z=r}
        end
    end

    if pawn then
        local pa=eye_angles(pawn)
        if pa then return pa end
    end

    return {x=0,y=0,z=0}
end

local function cmd_yaw(cmd,pawn)
    local a=cmd_angles(cmd,pawn)
    return a.y or 0
end

local function set_cmd_angles(cmd,pawn,pitch,yaw,roll)
    local ang=cmd_angles(cmd,pawn)
    ang.x=type(pitch)=="number" and pitch or ang.x
    ang.y=type(yaw)=="number" and yaw or ang.y
    ang.z=type(roll)=="number" and roll or (ang.z or 0)
    pcall(function() cmd.viewangles=EulerAngles(ang.x,ang.y,ang.z) end)
    pcall(function() cmd:SetViewAngles(EulerAngles(ang.x,ang.y,ang.z)) end)
    pcall(function() cmd.viewangles=ang end)
end

local function cmd_buttons(cmd)
    local ok,b=pcall(function() return cmd:GetButtons() end)
    if ok and type(b)=="number" then return b end
    ok,b=pcall(function() return cmd.buttons end)
    if ok and type(b)=="number" then return b end
    return 0
end

local function set_cmd_buttons(cmd,b)
    pcall(function() cmd:SetButtons(b) end)
    pcall(function() cmd.buttons=b end)
end

local function move_buttons(cmd,fwd,side)
    local IN_FORWARD=8
    local IN_BACK=16
    local IN_MOVELEFT=512
    local IN_MOVERIGHT=1024
    local b=cmd_buttons(cmd)
    if not bit or not bit.bor then return end
    b=bit.band(b,bit.bnot(bit.bor(IN_FORWARD,IN_BACK,IN_MOVELEFT,IN_MOVERIGHT)))
    if fwd>0.01 then
        b=bit.bor(b,IN_FORWARD)
    elseif fwd<-0.01 then
        b=bit.bor(b,IN_BACK)
    end
    if side>0.01 then
        b=bit.bor(b,IN_MOVERIGHT)
    elseif side<-0.01 then
        b=bit.bor(b,IN_MOVELEFT)
    end
    set_cmd_buttons(cmd,b)
end

local function apply_local(cmd,fwd,side)
    fwd=clamp(fwd,-MOVE_MAX,MOVE_MAX)
    side=clamp(side,-MOVE_MAX,MOVE_MAX)
    local ok=pcall(function() cmd:SetForwardMove(fwd) end)
    if not ok then pcall(function() cmd.forwardmove=fwd end) end
    ok=pcall(function() cmd:SetSideMove(side) end)
    if not ok then pcall(function() cmd.sidemove=side end) end
    move_buttons(cmd,fwd,side)
end

local function apply_world(cmd,pawn,wx,wy)
    local yaw=math.rad(cmd_yaw(cmd,pawn))
    local cy=math.cos(yaw)
    local sy=math.sin(yaw)
    local fwd=wx*cy+wy*sy
    local side=-wx*sy+wy*cy
    apply_local(cmd,fwd,side)
end

local function quick_stop(cmd,pawn,v)
    local wx=clamp(-v.x*BODY_QUICKSTOP_GAIN,-MOVE_MAX,MOVE_MAX)
    local wy=clamp(-v.y*BODY_QUICKSTOP_GAIN,-MOVE_MAX,MOVE_MAX)
    apply_world(cmd,pawn,wx,wy)
end

local function jump_duck(cmd,jump,duck)
    local IN_JUMP=2
    local IN_DUCK=4
    if not bit or not bit.bor then return end
    local b=cmd_buttons(cmd)
    b=bit.band(b,bit.bnot(bit.bor(IN_JUMP,IN_DUCK)))
    if jump then b=bit.bor(b,IN_JUMP) end
    if duck then b=bit.bor(b,IN_DUCK) end
    set_cmd_buttons(cmd,b)
end

local function predict_xy(pos,m,pred_t)
    return
        pos.x + m.vx*pred_t + 0.5*m.ax*pred_t*pred_t,
        pos.y + m.vy*pred_t + 0.5*m.ay*pred_t*pred_t
end

local function choose_axis(mypos,px,py,cur_axis)
    local gx=math.abs(px-mypos.x)
    local gy=math.abs(py-mypos.y)
    local want=(gx>gy) and "Y" or "X"

    if not cur_axis then return want end
    if cur_axis==want then return cur_axis end

    if cur_axis=="X" then
        if gx>gy*BODY_AXIS_SWITCH_RATIO then return "Y" end
        return "X"
    else
        if gy>gx*BODY_AXIS_SWITCH_RATIO then return "X" end
        return "Y"
    end
end

local function head_lock(cmd,pawn,mypos,ent,tpos,m,tang,myrawvel)
    if tang then
        local pitch=HEAD_PITCH_ENABLE and norm_pitch(tang.x or 0) or nil
        local yaw=HEAD_YAW_ENABLE and norm_yaw(tang.y or 0) or nil
        set_cmd_angles(cmd,pawn,pitch,yaw,nil)
    end

    local pred_t=clamp(
        HEAD_BASE_PRED + latency:GetValue()*0.001*HEAD_LATENCY_SCALE,
        HEAD_BASE_PRED,
        HEAD_MAX_PRED
    )

    local cx=tpos.x + m.vx*pred_t
    local cy=tpos.y + m.vy*pred_t

    local gap_x=cx-mypos.x
    local gap_y=cy-mypos.y

    local mom_x=(myrawvel.x or 0.0)*pred_t
    local mom_y=(myrawvel.y or 0.0)*pred_t

    local target_gap_x=0.0
    local target_gap_y=0.0

    if math.abs(gap_x)>HEAD_GAP_DEADZONE then
        if (gap_x>0 and gap_x-mom_x<0) or (gap_x<0 and gap_x-mom_x>0) then
            target_gap_x=-gap_x*HEAD_BRAKE_MULT
        else
            target_gap_x=gap_x
        end
    end

    if math.abs(gap_y)>HEAD_GAP_DEADZONE then
        if (gap_y>0 and gap_y-mom_y<0) or (gap_y<0 and gap_y-mom_y>0) then
            target_gap_y=-gap_y*HEAD_BRAKE_MULT
        else
            target_gap_y=gap_y
        end
    end

    local wx=clamp(target_gap_x*HEAD_TRACK_MULT,-HEAD_MAX_MOVE,HEAD_MAX_MOVE)
    local wy=clamp(target_gap_y*HEAD_TRACK_MULT,-HEAD_MAX_MOVE,HEAD_MAX_MOVE)

    apply_world(cmd,pawn,wx,wy)

    local jump=(m.vz or 0.0)>HEAD_JUMP_DZVEL
    local duck=duck_amount(ent)>0.5 or (m.vz or 0.0)<HEAD_DUCK_DZVEL
    jump_duck(cmd,jump,duck)
end

local function block_strafe(cmd,pawn,mypos,tpos,m,tang,myrawvel)
    if tang then
        set_cmd_angles(cmd,pawn,nil,norm_yaw(tang.y or 0),nil)
    end

    local pred_t=clamp(
        BODY_BASE_PRED + latency:GetValue()*0.001*BODY_LATENCY_SCALE,
        BODY_BASE_PRED,
        BODY_MAX_PRED
    )

    local px,py=predict_xy(tpos,m,pred_t)
    axis=choose_axis(mypos,px,py,axis)

    local gap_x=px-mypos.x
    local gap_y=py-mypos.y

    local mom_x=(myrawvel.x or 0.0)*pred_t
    local mom_y=(myrawvel.y or 0.0)*pred_t

    local wx=0.0
    local wy=0.0

    if axis=="X" then
        local err=gap_x
        if math.abs(err)>BODY_DEADZONE then
            if (err>0 and err-mom_x<0) or (err<0 and err-mom_x>0) then
                wx=clamp(-err*BODY_BRAKE_MULT,-MOVE_MAX,MOVE_MAX)
            else
                wx=clamp(err*BODY_GAIN,-MOVE_MAX,MOVE_MAX)
            end
            mode="STRAFE"
        else
            mode="IDLE"
            quick_stop(cmd,pawn,myrawvel)
            return
        end
    else
        local err=gap_y
        if math.abs(err)>BODY_DEADZONE then
            if (err>0 and err-mom_y<0) or (err<0 and err-mom_y>0) then
                wy=clamp(-err*BODY_BRAKE_MULT,-MOVE_MAX,MOVE_MAX)
            else
                wy=clamp(err*BODY_GAIN,-MOVE_MAX,MOVE_MAX)
            end
            mode="STRAFE"
        else
            mode="IDLE"
            quick_stop(cmd,pawn,myrawvel)
            return
        end
    end

    apply_world(cmd,pawn,wx,wy)
end

local function clear_target()
    target=nil
    axis=nil
end

local function valid_target()
    if not target then return false end
    if not valid_pawn(target) then
        clear_target()
        return false
    end
    return true
end

local function on_head(mypos,ent,tpos)
    local dx=tpos.x-mypos.x
    local dy=tpos.y-mypos.y
    local xyd=math.sqrt(dx*dx+dy*dy)
    local hz=target_head_z(ent,tpos.z)
    local dz=mypos.z-hz
    return xyd<=HEAD_XY_RADIUS and math.abs(dz)<=HEAD_Z_TOLERANCE
end

local function collect(class,out,seen)
    local ok,list=pcall(function() return entities.FindByClass(class) end)
    if not ok or not list then return end
    for i=1,#list do
        local ent=list[i]
        local ok2,idx=pcall(function() return ent:GetIndex() end)
        if ok2 and idx and not seen[idx] then
            seen[idx]=true
            table.insert(out,ent)
        end
    end
end

local function pawns()
    local out,seen={},{}
    collect("C_CSPlayerPawn",out,seen)
    collect("CCSPlayerPawn",out,seen)
    collect("CCSPlayer",out,seen)
    return out
end

callbacks.Register("CreateMove","BB51_CM",function(cmd)
    if not on:GetValue() then
        mode="OFF"
        clear_target()
        return
    end

    local me=local_pawn()
    if not me then
        mode="SEARCHING"
        return
    end

    local mypos=me:GetAbsOrigin()
    if not valid_vec(mypos) then return end

    local myidx=me:GetIndex()
    local myteam=team(me)

    if not valid_target() then
        local list=pawns()
        local best_dsq=math.huge
        local best=nil
        local best_pos=nil

        for i=1,#list do
            local p=list[i]
            local ok,pidx=pcall(function() return p:GetIndex() end)

            if ok and pidx and pidx~=myidx and valid_pawn(p) then
                local pt=team(p)
                local is_enemy=(myteam~=0 and pt~=0 and myteam~=pt)
                if not is_enemy then
                    local pos=p:GetAbsOrigin()
                    if valid_vec(pos) then
                        local dx=pos.x-mypos.x
                        local dy=pos.y-mypos.y
                        local dz=pos.z-mypos.z
                        local dsq=dx*dx+dy*dy+dz*dz
                        if dsq<best_dsq then
                            best_dsq=dsq
                            best=p
                            best_pos=pos
                        end
                    end
                end
            end
        end

        if best and best_pos then
            target=best
            local m=motion(best)
            local pred_t=clamp(
                BODY_BASE_PRED + latency:GetValue()*0.001*BODY_LATENCY_SCALE,
                BODY_BASE_PRED,
                BODY_MAX_PRED
            )
            local px,py=predict_xy(best_pos,m,pred_t)
            axis=choose_axis(mypos,px,py,nil)
        else
            mode="SEARCHING"
            quick_stop(cmd,me,raw_vel(me))
            return
        end
    end

    if not valid_target() then
        quick_stop(cmd,me,raw_vel(me))
        return
    end

    local tpos=target:GetAbsOrigin()
    if not valid_vec(tpos) then return end

    local m=motion(target)
    local myrawvel=raw_vel(me)
    local tang=eye_angles(target)

    if on_head(mypos,target,tpos) then
        mode=duck_amount(target)>0.5 and "HEAD-CROUCH" or "HEAD-LOCK"
        head_lock(cmd,me,mypos,target,tpos,m,tang,myrawvel)
        return
    end

    block_strafe(cmd,me,mypos,tpos,m,tang,myrawvel)
end)

callbacks.Register("Draw","BB51_DRW",function()
    if menu then
        local open=false
        local ok,active=pcall(function() return menu:IsActive() end)
        if ok and active then open=true end
        wnd:SetInvisible(not open)
    end

    local me=local_pawn()
    if not me then
        return
    end

    draw.SetFont(font)

    local label,r,g,b
    if not on:GetValue() then
        label="Blockbot: OFF"
        r,g,b=140,140,140
    elseif valid_target() then
        label="Blockbot: "..ent_name(target)
        r,g,b=0,220,80
    else
        label="Blockbot: SEARCHING"
        r,g,b=255,200,50
    end

    local tw,th=draw.GetTextSize(label)
    local px=hudx:GetValue()
    local py=hudy:GetValue()

    draw.Color(10,10,10,160)
    draw.FilledRect(px-4,py-3,px+tw+4,py+th+3)
    draw.Color(r,g,b,255)
    draw.Text(px,py,label)

    if not valid_target() then return end

    local ok,tpos=pcall(function() return target:GetAbsOrigin() end)
    if not ok or not valid_vec(tpos) then return end

    if dot:GetValue() then
        local dr,dg,db,da=dotc:GetValue()
        local hx,hy=client.WorldToScreen(Vector3(tpos.x,tpos.y,tpos.z+73.0))
        if hx and hy then
            draw.Color(dr,dg,db,math.floor(da*0.25))
            draw.FilledCircle(hx,hy,10)
            draw.Color(dr,dg,db,da)
            draw.FilledCircle(hx,hy,6)
            draw.Color(0,0,0,160)
            draw.OutlinedCircle(hx,hy,6)
            draw.Color(255,255,255,230)
            draw.FilledCircle(hx,hy,2)
        end
    end

    if grid:GetValue() then
        local gr,gg,gb,ga=gridc:GetValue()
        local half=56.0
        local divs=7
        local step=half/divs
        local gz=tpos.z+2.0

        local function line(ax,ay,bx,by,a)
            local x1,y1=client.WorldToScreen(Vector3(ax,ay,gz))
            local x2,y2=client.WorldToScreen(Vector3(bx,by,gz))
            if x1 and y1 and x2 and y2 then
                draw.Color(gr,gg,gb,math.floor(ga*a))
                draw.Line(x1,y1,x2,y2)
            end
        end

        for i=-divs,divs do
            local o=i*step
            local axisline=(i==0)
            local fade=1.0-math.abs(o)/half
            local a=axisline and 0.90 or (fade*0.40+0.06)
            line(tpos.x-half,tpos.y+o,tpos.x+half,tpos.y+o,a)
            line(tpos.x+o,tpos.y-half,tpos.x+o,tpos.y+half,a)
        end
    end
end)

callbacks.Register("Unload","BB51_UNL",function()
    callbacks.Unregister("CreateMove","BB51_CM")
    callbacks.Unregister("Draw","BB51_DRW")
end)
