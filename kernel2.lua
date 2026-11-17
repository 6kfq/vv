-- ═══════════════════════════════════════════════════════════════════════════════
--  OUTSPAMMER v12
-- ═══════════════════════════════════════════════════════════════════════════════
--  NOVIDADES v12:
--   • DETECCAO DE VOO — se estiver voando, o script pausa os ataques sozinho
--   • PAUSA DE FUGA — F7 pausa 3s, F8 pausa 10s, sem desligar o script
--   • F1 = kill switch total
--   • VIM respeita o voo e a pausa
--   • 4 travas no click (nao atrapalha o ataque basico)
--   • BLOCKLIST: Fly e ExtraKey1
-- ═══════════════════════════════════════════════════════════════════════════════

local RS         = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenSvc   = game:GetService("TweenService")

local LP = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════════════════════════
--  VERIFICACOES DE BOOT
-- ═══════════════════════════════════════════════════════════════════════════════
local fails = {}
local function check(name, cond, detail)
    if cond then print(("[CHECK] OK   %s"):format(name))
    else fails[#fails+1] = name; warn(("[CHECK] FAIL %s %s"):format(name, tostring(detail or ""))) end
    return cond
end

local Modules  = RS:FindFirstChild("Modules")
local Knit     = Modules and Modules:FindFirstChild("Knit")
local Services = Knit and Knit:FindFirstChild("Services")
local AS       = Services and Services:FindFirstChild("AbilityService")
local RFf      = AS and AS:FindFirstChild("RF")
local AR       = RFf and RFf:FindFirstChild("AbilityRequest")
local GAI      = RFf and RFf:FindFirstChild("GetAbilitiesInfo")

check("ReplicatedStorage.Modules", Modules ~= nil)
check("Modules.Knit", Knit ~= nil)
check("Knit.Services", Services ~= nil)
check("AbilityService", AS ~= nil)
check("AbilityService.RF", RFf ~= nil)
check("RF.AbilityRequest", AR ~= nil and AR:IsA("RemoteFunction"))
check("RF.GetAbilitiesInfo", GAI ~= nil and GAI:IsA("RemoteFunction"))

if #fails > 0 then
    warn("[OUTSPAMMER] estrutura invalida: " .. table.concat(fails, ", ") .. " — abortando")
    return
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  CONFIG
-- ═══════════════════════════════════════════════════════════════════════════════
local CFG = {
    SENTINEL      = "CurrentAbility",
    SLACK         = 0.05,
    REJECT_WAIT   = 0.10,
    HOLD_TIME     = 0.07,

    CLICK_ON            = true,
    CLICK_HZ            = 7,
    CLICK_BUTTON        = 0,
    CLICK_PAUSE_ABILITY = 0.35,
    CLICK_ONLY_TARGET   = true,

    TARGET          = true,
    TARGET_RANGE    = 120,
    TARGET_HYST     = 15,
    TARGET_REFRESH  = 0.10,
    TARGET_MAXFAIL  = 3,

    RESPECT_FLY     = true,    -- ★ pausa quando estiver voando
    FLY_CHECK_HZ    = 10,      -- quantas vezes/s checa o voo

    PAUSE_SHORT     = 3,       -- F7
    PAUSE_LONG      = 10,      -- F8

    VERBOSE         = true,

    HK_SWITCH       = Enum.KeyCode.F1,   -- kill switch total
    HK_PANIC        = Enum.KeyCode.F2,   -- panico (para o spam)
    HK_VIM          = Enum.KeyCode.F3,
    HK_TARGET       = Enum.KeyCode.F4,
    HK_REPORT       = Enum.KeyCode.F6,
    HK_PAUSE_SHORT  = Enum.KeyCode.F7,   -- pausa 3s (fugir)
    HK_PAUSE_LONG   = Enum.KeyCode.F8,   -- pausa 10s
}

local BLACKLIST = {
    Fly       = "toggle (HoldTime=inf) — o script nao deve tocar",
    ExtraKey1 = "ServerCooldown=true — o servidor valida e rejeita",
}

local KEYMAP = {
    [Enum.KeyCode.Q] = "Q",   [Enum.KeyCode.E] = "E",
    [Enum.KeyCode.R] = "R",   [Enum.KeyCode.F] = "F",
    [Enum.KeyCode.C] = "C",   [Enum.KeyCode.X] = "X",
    [Enum.KeyCode.Z] = "Z",   [Enum.KeyCode.V] = "V",
    [Enum.KeyCode.G] = "G",   [Enum.KeyCode.T] = "T",
    [Enum.KeyCode.H] = "ExtraKey1",
    [Enum.KeyCode.J] = "ExtraKey2",
    [Enum.KeyCode.K] = "ExtraKey3",
    [Enum.KeyCode.L] = "ExtraKey4",
}

-- ═══════════════════════════════════════════════════════════════════════════════
--  ESTADO
-- ═══════════════════════════════════════════════════════════════════════════════
local scriptEnabled = true
local activeKey     = nil
local autoClickOn   = CFG.CLICK_ON
local targetOn      = CFG.TARGET
local running       = true

local cd, baseCd, holdTime, stats = {}, {}, {}, {}
local clickSent, kills, totalHit, totalMiss = 0, 0, 0, 0
local clickBlockedUntil = 0
local lastHealth = {}
local lastTargetName, lastTargetDist = "nil", 0

local pausedUntil   = 0
local flyingState   = false
local pauseOpenUntil = 0     -- pausa automatica quando detecta voo

local function st(k)
    stats[k] = stats[k] or {
        hit=0, miss=0, last=nil, consecMiss=0,
        rejectEma=CFG.REJECT_WAIT, attempts=0, dead=false,
    }
    return stats[k]
end
local function initKey(k)
    cd[k]=cd[k] or 0; baseCd[k]=baseCd[k] or 0
    holdTime[k]=holdTime[k] or 0; st(k)
end
local function isBlacklisted(k) return BLACKLIST[k] ~= nil end

local function myRoot()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function hasChar() return myRoot() ~= nil end

-- ═══════════════════════════════════════════════════════════════════════════════
--  DETECCAO DE VOO
-- ═══════════════════════════════════════════════════════════════════════════════
local function isFlying()
    local c = LP.Character
    if not c then return false end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    local h = c:FindFirstChildOfClass("Humanoid")
    if not hrp or not h then return false end

    -- 1) flags no personagem
    if c:FindFirstChild("Flying") or c:FindFirstChild("Fly")
       or c:FindFirstChild("IsFlying") or c:FindFirstChild("Flight") then
        return true
    end

    -- 2) CharacterValues
    local cv = c:FindFirstChild("CharacterValues")
    if cv then
        if cv:FindFirstChild("Flying") or cv:FindFirstChild("Fly")
           or cv:FindFirstChild("IsFlying") then
            return true
        end
    end

    -- 3) atributos no char
    for _, a in ipairs({"Flying","Fly","IsFlying","isFlying","Flight"}) do
        local ok, v = pcall(function() return c:GetAttribute(a) end)
        if ok and v == true then return true end
    end

    -- 4) estado do humanoid
    local ok, state = pcall(function() return h:GetState() end)
    if ok then
        if state == Enum.HumanoidStateType.Flying then return true end
        if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.PlatformStanding then
            -- distingue queda normal de voo pela velocidade
            local v = hrp.AssemblyLinearVelocity
            local horiz = Vector3.new(v.X, 0, v.Z).Magnitude
            if v.Y > 12 then return true end                    -- subindo
            if horiz > 30 and math.abs(v.Y) < 25 then return true end  -- planando
        end
    end

    -- 5) PlatformStand
    if h.PlatformStand then return true end

    return false
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  TARGET
-- ═══════════════════════════════════════════════════════════════════════════════
local function isAlive(c)
    if not c or c == LP.Character then return false end
    if c.Parent ~= workspace then return false end
    local h = c:FindFirstChildOfClass("Humanoid")
    if not h or h.Health <= 0 then return false end
    if c:FindFirstChild("Ragdoll") or c:FindFirstChild("Dead") then return false end
    return true
end

local function distTo(c)
    local mr = myRoot()
    local tr = c and c:FindFirstChild("HumanoidRootPart")
    if not mr or not tr then return nil end
    return (tr.Position - mr.Position).Magnitude
end

local function findNearest()
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local c = p.Character
            if isAlive(c) then
                local d = distTo(c)
                if d and d <= CFG.TARGET_RANGE and d < bestDist then
                    best, bestDist = c, d
                end
            end
        end
    end
    return best, bestDist
end

local cachedTarget, cachedAt = nil, 0
local function invalidateTarget() cachedTarget = nil; cachedAt = 0 end

local function getTargetChar()
    if not targetOn then return nil, 0 end
    local now = os.clock()
    if cachedTarget and (now - cachedAt) < CFG.TARGET_REFRESH then
        if isAlive(cachedTarget) then
            local d = distTo(cachedTarget)
            if d and d <= CFG.TARGET_RANGE then
                local nb, nd = findNearest()
                if nb and nd and (d - nd) > CFG.TARGET_HYST then
                    cachedTarget, cachedAt = nb, now
                    return nb, nd
                end
                return cachedTarget, d
            end
        end
        cachedTarget = nil
    end
    local t, d = findNearest()
    cachedTarget, cachedAt = t, now
    return t, d
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  GUI
-- ═══════════════════════════════════════════════════════════════════════════════
local notifyHolder, statusLabel

local function buildGui()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return false end
    local old = pg:FindFirstChild("SpamGUI")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "SpamGUI"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 9999
    gui.Parent = pg

    local panel = Instance.new("Frame")
    panel.BackgroundColor3 = Color3.fromRGB(12,12,16)
    panel.BackgroundTransparency = 0.2
    panel.BorderSizePixel = 0
    panel.AnchorPoint = Vector2.new(1,0)
    panel.Position = UDim2.new(1,-12,0,12)
    panel.Size = UDim2.new(0,278,0,26)
    panel.Parent = gui
    local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0,6); pc.Parent = panel
    local ps = Instance.new("UIStroke"); ps.Color = Color3.fromRGB(60,60,75)
    ps.Thickness = 1; ps.Transparency = 0.35; ps.Parent = panel

    statusLabel = Instance.new("TextLabel")
    statusLabel.BackgroundTransparency = 1
    statusLabel.Size = UDim2.new(1,-14,1,0)
    statusLabel.Position = UDim2.new(0,8,0,0)
    statusLabel.Font = Enum.Font.Code
    statusLabel.TextSize = 12
    statusLabel.TextColor3 = Color3.fromRGB(230,230,240)
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Text = "v12"
    statusLabel.Parent = panel

    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    holder.AnchorPoint = Vector2.new(1,0)
    holder.Position = UDim2.new(1,-12,0,46)
    holder.Size = UDim2.new(0,272,0,340)
    holder.Parent = gui
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0,5)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = holder

    notifyHolder = holder
    return true
end

local C = {
    ON=Color3.fromRGB(85,210,120), OFF=Color3.fromRGB(225,85,85),
    SWAP=Color3.fromRGB(235,185,60), INFO=Color3.fromRGB(85,150,235),
    PANIC=Color3.fromRGB(240,55,55), VIM=Color3.fromRGB(175,125,235),
    TGT=Color3.fromRGB(75,200,220), KILL=Color3.fromRGB(255,205,60),
    WARN=Color3.fromRGB(235,140,60), FLY=Color3.fromRGB(120,190,255),
}

local function notify(text, color, duration)
    if (not notifyHolder or not notifyHolder.Parent) and not buildGui() then return end
    duration = duration or 1.3
    local card = Instance.new("Frame")
    card.BackgroundColor3 = Color3.fromRGB(14,14,18)
    card.BackgroundTransparency = 0.1
    card.BorderSizePixel = 0
    card.Size = UDim2.new(0,264,0,26)
    card.Position = UDim2.new(0,45,0,0)
    card.Parent = notifyHolder
    local cr = Instance.new("UICorner"); cr.CornerRadius = UDim.new(0,6); cr.Parent = card
    local sk = Instance.new("UIStroke"); sk.Color = color
    sk.Thickness = 1.5; sk.Transparency = 0.15; sk.Parent = card
    local bar = Instance.new("Frame"); bar.BackgroundColor3 = color
    bar.BorderSizePixel = 0; bar.Size = UDim2.new(0,3,1,0); bar.Parent = card
    local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0,6); bc.Parent = bar
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.new(0,12,0,0)
    lbl.Size = UDim2.new(1,-18,1,0)
    lbl.Font = Enum.Font.GothamBold
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(242,242,248)
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = card

    TweenSvc:Create(card, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = UDim2.new(0,0,0,0) }):Play()
    task.delay(duration, function()
        if not card.Parent then return end
        TweenSvc:Create(card, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
        TweenSvc:Create(sk,  TweenInfo.new(0.2), { Transparency = 1 }):Play()
        TweenSvc:Create(lbl, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
        TweenSvc:Create(bar, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
        task.wait(0.24)
        if card.Parent then card:Destroy() end
    end)
end

local function refreshStatus()
    if not statusLabel then return end
    local flags = ""
    if not scriptEnabled then flags = flags .. "SCRIPT-OFF "
    elseif os.clock() < pausedUntil then
        flags = flags .. ("PAUSA %.0fs "):format(pausedUntil - os.clock())
    elseif flyingState then flags = flags .. "VOO "
    end
    statusLabel.Text = ("%s%-8s V%s T%s %s"):format(
        flags, activeKey or "—",
        autoClickOn and "1" or "0",
        targetOn and "1" or "0",
        lastTargetName:sub(1,7))

    if not scriptEnabled then statusLabel.TextColor3 = C.OFF
    elseif os.clock() < pausedUntil then statusLabel.TextColor3 = C.SWAP
    elseif flyingState then statusLabel.TextColor3 = C.FLY
    elseif activeKey then statusLabel.TextColor3 = C.ON
    else statusLabel.TextColor3 = Color3.fromRGB(140,140,155) end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  VIM
-- ═══════════════════════════════════════════════════════════════════════════════
local VIMsvc = game:GetService("VirtualInputManager")
local clickMethod = "none"
do
    local hasM1 = (function() local ok,v = pcall(function() return mouse1click end); return ok and v ~= nil end)()
    local hasM2 = (function() local ok,v = pcall(function() return mouse1press end); return ok and v ~= nil end)()
    if hasM1 then clickMethod = "mouse1click"
    elseif hasM2 then clickMethod = "mouse1press"
    elseif VIMsvc then clickMethod = "vim" end
    print("[CHECK] metodo de clique:", clickMethod)
end

local function blockClick(sec)
    local t = os.clock() + sec
    if t > clickBlockedUntil then clickBlockedUntil = t end
end

local function vimCanClick()
    if not autoClickOn then return false end
    if clickMethod == "none" then return false end
    if not scriptEnabled then return false end
    if os.clock() < pausedUntil then return false end     -- ★ pausa de fuga
    if CFG.RESPECT_FLY and flyingState then return false end -- ★ voando
    if os.clock() < clickBlockedUntil then return false end
    if not hasChar() then return false end
    if CFG.CLICK_ONLY_TARGET then
        local t, d = getTargetChar()
        if not t then return false end
        if not d or d > CFG.TARGET_RANGE then return false end
    end
    return true
end

local function doClick()
    if not vimCanClick() then return end
    if clickMethod == "mouse1click" then
        pcall(mouse1click)
    elseif clickMethod == "mouse1press" then
        pcall(function() mouse1press(); task.wait(0.006); mouse1release() end)
    else
        pcall(function()
            VIMsvc:SendMouseButtonEvent(0,0,CFG.CLICK_BUTTON,true,game,1)
            task.wait(0.005)
            VIMsvc:SendMouseButtonEvent(0,0,CFG.CLICK_BUTTON,false,game,1)
        end)
    end
    clickSent += 1
    blockClick(1 / CFG.CLICK_HZ)
end

task.spawn(function()
    while running do
        doClick()
        task.wait(0.02)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  MONITOR DE VOO
-- ═══════════════════════════════════════════════════════════════════════════════
task.spawn(function()
    while running do
        local f = isFlying()
        if f ~= flyingState then
            flyingState = f
            if f then
                notify("VOO — spam pausado", C.FLY, 2)
                print("[FLY] voo detectado — pausando")
            else
                notify("Voo terminou — retomando", C.INFO, 1.5)
                print("[FLY] voo terminou — retomando")
            end
            refreshStatus()
        end
        task.wait(1 / CFG.FLY_CHECK_HZ)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  MAPA
-- ═══════════════════════════════════════════════════════════════════════════════
local function syncMap(silent)
    local ok, info = pcall(function() return GAI:InvokeServer() end)
    if not ok or type(info) ~= "table" then
        warn("[CHECK] GetAbilitiesInfo falhou:", tostring(info))
        if not silent then notify("Falha: GetAbilitiesInfo", C.OFF) end
        return false
    end
    local n = 0
    local list = {}
    for key, d in pairs(info) do
        if type(d) == "table" then
            if type(d.Cooldown) == "number" then baseCd[key] = d.Cooldown end
            if type(d.HoldTime) == "number" then holdTime[key] = d.HoldTime
            elseif d.HoldTime == math.huge then holdTime[key] = math.huge end
            initKey(key); n += 1
            list[#list+1] = ("%s(cd%s%s%s)"):format(key, tostring(d.Cooldown),
                d.ServerCooldown and "/S" or "",
                isBlacklisted(key) and "/BLK" or "")
        end
    end
    table.sort(list)
    print("[CHECK] habilidades: " .. table.concat(list, " "))
    if not silent then notify(("Habilidades: %d"):format(n), C.INFO, 1.6) end
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  DISPARO
-- ═══════════════════════════════════════════════════════════════════════════════
local function canAct()
    if not scriptEnabled then return false, "script off" end
    if os.clock() < pausedUntil then return false, "pausado" end
    if CFG.RESPECT_FLY and flyingState then return false, "voando" end
    if not hasChar() then return false, "sem personagem" end
    return true, nil
end

local function fireKey(key)
    local ok2, why = canAct()
    if not ok2 then return nil, false, why end
    if isBlacklisted(key) then return nil, false, "blacklist" end

    local target, dist = getTargetChar()
    lastTargetName = target and target.Name or "nil"
    lastTargetDist = dist or 0

    if targetOn and not target then return nil, false, "sem alvo" end

    local ht = holdTime[key] or 0
    local ok, ret = pcall(function()
        return AR:InvokeServer(key, true, CFG.SENTINEL, target)
    end)

    if not ok then return nil, false, tostring(ret) end

    if type(ret) == "number" then
        blockClick(CFG.CLICK_PAUSE_ABILITY)
        if ht > 0 and ht < math.huge and ht > 0.02 then
            task.delay(CFG.HOLD_TIME, function()
                pcall(function() AR:InvokeServer(key, false, CFG.SENTINEL, target) end)
            end)
        end
        return ret, true, nil
    end
    return ret, false, nil
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  WORKER
-- ═══════════════════════════════════════════════════════════════════════════════
local function worker()
    while running do
        local ok2 = canAct()
        if not ok2 then
            task.wait(0.15)
        else
            local key = activeKey
            if key then
                local now = os.clock()
                if now >= (cd[key] or 0) then
                    local ret, accepted, err = fireKey(key)
                    local s = st(key)
                    s.attempts += 1
                    if accepted then
                        cd[key] = os.clock() + ret + CFG.SLACK
                        s.hit += 1; totalHit += 1; s.last = ret
                        s.consecMiss = 0; s.dead = false
                        if CFG.VERBOSE then
                            print(("[FIRE] %s OK cd=%s alvo=%s %.0f"):format(
                                key, tostring(ret), lastTargetName, lastTargetDist))
                        end
                    else
                        s.miss += 1; totalMiss += 1; s.last = ret
                        s.consecMiss += 1
                        if s.consecMiss >= CFG.TARGET_MAXFAIL then
                            if CFG.VERBOSE then
                                print(("[TGT] %s rejeitado %dx (%s %.0f) -> troca"):format(
                                    key, s.consecMiss, lastTargetName, lastTargetDist))
                            end
                            invalidateTarget(); s.consecMiss = 0
                        end
                        if not s.dead and s.attempts >= 60 and s.hit == 0 then
                            s.dead = true
                            notify(("%s nunca acertou"):format(key), C.WARN, 2.5)
                            warn(("[FIRE] %s 60 tent 0 acertos err=%s"):format(
                                key, tostring(err or ret)))
                        end
                        cd[key] = os.clock() + s.rejectEma
                    end
                    if CFG.VERBOSE and s.attempts % 30 == 0 then
                        print(("[STAT] %s hit=%d miss=%d alvo=%s %.0f"):format(
                            key, s.hit, s.miss, lastTargetName, lastTargetDist))
                    end
                else
                    task.wait(math.min(0.03, math.max(0.004, cd[key] - now)))
                end
            else
                task.wait(0.05)
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  CONTROLE
-- ═══════════════════════════════════════════════════════════════════════════════
local function setActive(name)
    if isBlacklisted(name) then
        notify(("%s bloqueada"):format(name), C.WARN, 2.2)
        warn(("[KEY] %s BLACKLIST: %s"):format(name, BLACKLIST[name]))
        return
    end
    if activeKey == name then
        local prev = activeKey; activeKey = nil
        notify(("%s off"):format(prev), C.OFF, 1.1)
        print(("[KEY] OFF %s"):format(prev))
    else
        local prev = activeKey
        activeKey = name
        st(name).attempts = 0; st(name).consecMiss = 0; cd[name] = 0
        if prev then
            notify(("Off: %s"):format(prev), C.SWAP, 1.0)
            print(("[KEY] %s -> %s"):format(prev, name))
        end
        notify((">> %s ON <<"):format(name), C.ON, 1.3)
        print(("[KEY] ON %s cd=%s hold=%s"):format(
            name, tostring(baseCd[name]), tostring(holdTime[name])))
    end
    refreshStatus()
end

local function pauseFor(sec, label)
    pausedUntil = os.clock() + sec
    notify(("PAUSA %.0fs %s"):format(sec, label or ""), C.SWAP, 2)
    print(("[PAUSE] pausado %.1fs %s"):format(sec, label or ""))
    refreshStatus()
end

local function panic()
    activeKey = nil
    notify("!! PANICO !!", C.PANIC, 2)
    print("[KEY] PANICO")
    refreshStatus()
end

local function killSwitch()
    if scriptEnabled then
        scriptEnabled = false
        activeKey = nil; autoClickOn = false; targetOn = false
        invalidateTarget()
        notify("!! SCRIPT OFF !!", C.PANIC, 2.5)
        print("[SWITCH] DESLIGADO")
    else
        scriptEnabled = true
        notify(">> SCRIPT ON <<", C.ON, 2)
        print("[SWITCH] LIGADO")
        task.spawn(function() syncMap(true) end)
    end
    refreshStatus()
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  INPUT
-- ═══════════════════════════════════════════════════════════════════════════════
UIS.InputBegan:Connect(function(input, processed)
    local kc = input.KeyCode

    if kc == CFG.HK_SWITCH then killSwitch(); return end
    if kc == CFG.HK_PAUSE_SHORT then pauseFor(CFG.PAUSE_SHORT, "(fuga)"); return end
    if kc == CFG.HK_PAUSE_LONG  then pauseFor(CFG.PAUSE_LONG, "(fuga longa)"); return end

    if not scriptEnabled then return end

    if kc == CFG.HK_PANIC then panic(); return end
    if kc == CFG.HK_VIM then
        autoClickOn = not autoClickOn
        notify("VIM "..(autoClickOn and "ON" or "OFF"), C.VIM, 1.1)
        refreshStatus(); return
    end
    if kc == CFG.HK_TARGET then
        targetOn = not targetOn
        notify("TARGET "..(targetOn and "ON" or "OFF"), C.TGT, 1.1)
        refreshStatus(); return
    end
    if kc == CFG.HK_REPORT then getgenv().Spam.Report(); return end

    if processed then return end
    local name = KEYMAP[kc]
    if not name then return end
    if baseCd[name] == nil then
        notify(("%s sem habilidade"):format(name), C.WARN, 1.5)
        task.spawn(function() task.wait(0.5); syncMap(true) end)
    end
    setActive(name)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  START
-- ═══════════════════════════════════════════════════════════════════════════════
task.spawn(function()
    local tries = 0
    while not buildGui() and tries < 30 do tries += 1; task.wait(0.2) end
    check("GUI criada", notifyHolder ~= nil)

    notify("Carregando...", C.INFO, 1.0)
    syncMap()
    for k in pairs(baseCd) do initKey(k) end
    task.spawn(worker)
    refreshStatus()

    local acc = 0
    RunService.Heartbeat:Connect(function(dt)
        acc += dt
        if acc < 0.4 then return end
        acc = 0
        refreshStatus()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local h = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
                if h then
                    local prev = lastHealth[p]
                    if prev and prev > 0 and h.Health <= 0 then
                        kills += 1
                        notify(("KILL: %s"):format(p.Name), C.KILL, 2.0)
                        if cachedTarget == p.Character then invalidateTarget() end
                    end
                    lastHealth[p] = h.Health
                end
            end
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
--  API
-- ═══════════════════════════════════════════════════════════════════════════════
getgenv().Spam = {
    On  = function(k) setActive(k or activeKey or "Q") end,
    Off = function() activeKey = nil; notify("Spam OFF", C.OFF); refreshStatus() end,
    Key = function(k) setActive(k) end,
    KillSwitch = function() killSwitch() end,

    Pause  = function(sec) pauseFor(sec or 3, "(manual)") end,
    Resume = function() pausedUntil = 0; notify("Retomado", C.ON, 1.2); refreshStatus() end,
    IsPaused = function() return os.clock() < pausedUntil end,

    FlyCheck = function(v)
        CFG.RESPECT_FLY = (v ~= false)
        notify("Respeitar voo: "..tostring(CFG.RESPECT_FLY), C.FLY, 1.5)
    end,
    IsFlying = function() return isFlying() end,

    Click = function(v)
        autoClickOn = (v ~= false)
        notify("VIM "..(autoClickOn and "ON" or "OFF"), C.VIM, 1.1); refreshStatus()
    end,
    ClickHz = function(hz) CFG.CLICK_HZ = hz; notify("Click "..hz.."Hz", C.VIM, 1.2) end,
    ClickPause = function(s) CFG.CLICK_PAUSE_ABILITY = s; notify("Pausa "..s, C.VIM, 1.2) end,

    Target = function(v)
        targetOn = (v ~= false)
        notify("TARGET "..(targetOn and "ON" or "OFF"), C.TGT, 1.1); refreshStatus()
    end,
    Range = function(r) CFG.TARGET_RANGE = r; invalidateTarget(); notify("Range "..r, C.TGT, 1.2) end,

    Blacklist = function(k, add)
        if add == false then BLACKLIST[k] = nil; notify("Liberado: "..k, C.INFO, 1.5)
        else BLACKLIST[k] = "manual"; notify("Bloqueado: "..k, C.WARN, 1.5) end
    end,

    Sync = function() syncMap() end,

    Targets = function()
        local mr = myRoot()
        print("╔═══ ALVOS (range "..CFG.TARGET_RANGE..") ═══")
        if not mr then print("║ sem HumanoidRootPart"); print("╚"); return end
        local list = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local c = p.Character
                if c and c.Parent == workspace then
                    local hrp = c:FindFirstChild("HumanoidRootPart")
                    local h = c:FindFirstChildOfClass("Humanoid")
                    if hrp and h then
                        local d = (hrp.Position - mr.Position).Magnitude
                        list[#list+1] = { name=p.Name, d=d, hp=h.Health,
                            alive=isAlive(c), cur=(cachedTarget==c) }
                    end
                end
            end
        end
        table.sort(list, function(a,b) return a.d < b.d end)
        for i, e in ipairs(list) do
            print(("║ %d. %-22s %5.0f studs hp=%-4d %s%s%s"):format(
                i, e.name, e.d, e.hp,
                e.d <= CFG.TARGET_RANGE and "IN " or "OUT",
                e.alive and "" or " [morto]",
                e.cur and " <== ATUAL" or ""))
        end
        if #list == 0 then print("║ (nenhum)") end
        print("╚")
        notify(("Alvos: %d"):format(#list), C.TGT, 2)
    end,

    FlyInfo = function()
        local c = LP.Character
        print("╔═══ DIAGNOSTICO DE VOO ═══")
        print(("║ isFlying(): %s"):format(tostring(isFlying())))
        if c then
            local hrp = c:FindFirstChild("HumanoidRootPart")
            local h = c:FindFirstChildOfClass("Humanoid")
            print(("║ Humanoid state: %s"):format(
                h and tostring((function() local ok,s = pcall(function() return h:GetState() end); return ok and s or "?" end)()) or "?"))
            if hrp then
                local v = hrp.AssemblyLinearVelocity
                print(("║ velocidade: X=%.1f Y=%.1f Z=%.1f"):format(v.X, v.Y, v.Z))
            end
            print("║ filhos do char:")
            for _, ch in ipairs(c:GetChildren()) do
                if ch.Name:lower():find("fly") or ch.Name:lower():find("flight")
                   or ch.Name:lower():find("voo") then
                    print(("║   %-24s %s"):format(ch.Name, ch.ClassName))
                end
            end
            local cv = c:FindFirstChild("CharacterValues")
            if cv then
                print("║ CharacterValues:")
                for _, ch in ipairs(cv:GetChildren()) do
                    print(("║   %-24s = %s"):format(ch.Name, tostring(ch.Value)))
                end
            end
        else
            print("║ sem personagem")
        end
        print("╚")
    end,

    Test = function(k)
        k = k or activeKey
        if not k then notify("Test: sem tecla", C.WARN, 1.5); return end
        if isBlacklisted(k) then notify(k.." blacklist", C.WARN, 2); return end
        local prevCd, prevCache = cd[k], cachedTarget
        cd[k] = 0; invalidateTarget()
        local ret, ok2, err = fireKey(k)
        cd[k] = prevCd; cachedTarget = prevCache
        print(("╔═══ TESTE %s ═══"):format(k))
        print(("║ baseCd=%s hold=%s"):format(tostring(baseCd[k]), tostring(holdTime[k])))
        print(("║ script=%s pausado=%s voando=%s"):format(
            tostring(scriptEnabled), tostring(os.clock() < pausedUntil), tostring(flyingState)))
        print(("║ personagem: %s"):format(tostring(hasChar())))
        print(("║ alvo: %s a %.0f studs"):format(lastTargetName, lastTargetDist))
        print(("║ retorno: %s (%s)"):format(tostring(ret), typeof(ret)))
        print(("║ motivo: %s"):format(tostring(err)))
        print(("╚ %s"):format(ok2 and "ACEITO" or "REJEITADO"))
        notify(("%s: %s"):format(k, ok2 and "ACEITO" or "REJEITADO"),
            ok2 and C.ON or C.OFF, 2.5)
    end,

    Map = function()
        local t = {}
        for k, c in pairs(baseCd) do
            t[#t+1] = ("%s:cd%s%s%s"):format(k, tostring(c),
                (holdTime[k]==math.huge) and "/inf" or
                (holdTime[k] and holdTime[k]>0) and ("/h"..holdTime[k]) or "",
                isBlacklisted(k) and " BLOCKED" or "")
        end
        table.sort(t)
        print("╔═══ MAPA ═══"); for _,l in ipairs(t) do print("║ "..l) end; print("╚")
        notify("Mapa no console", C.INFO, 2)
    end,

    Report = function()
        local now = os.clock()
        print("╔═══ v12 REPORT ═══")
        print(("║ script: %s | tecla: %s"):format(
            scriptEnabled and "ON" or "OFF", activeKey or "nenhuma"))
        print(("║ pausa: %s | voo: %s (respeitar=%s)"):format(
            (now < pausedUntil) and ("%.1fs"):format(pausedUntil-now) or "nao",
            tostring(flyingState), tostring(CFG.RESPECT_FLY)))
        print(("║ VIM: %s (%s, %dHz, pausa %.2fs) | target: %s"):format(
            autoClickOn and "ON" or "OFF", clickMethod, CFG.CLICK_HZ,
            CFG.CLICK_PAUSE_ABILITY, targetOn and "ON" or "OFF"))
        print(("║ range=%d | cliques=%d | kills=%d"):format(
            CFG.TARGET_RANGE, clickSent, kills))
        print(("║ alvo: %s a %.0f studs"):format(lastTargetName, lastTargetDist))
        local t = {}
        for k, s in pairs(stats) do t[#t+1] = {k=k,s=s} end
        table.sort(t, function(a,b) return a.s.hit > b.s.hit end)
        for _, e in ipairs(t) do
            print(("║ %-11s cd=%-3s hit=%-6d miss=%-6d wait=%.1fs %s"):format(
                e.k, tostring(baseCd[e.k] or 0), e.s.hit, e.s.miss,
                math.max(0, (cd[e.k] or 0) - now), e.s.dead and "DEAD" or ""))
        end
        print(("╚ TOTAL hit=%d miss=%d"):format(totalHit, totalMiss))
        notify(("hit=%d miss=%d"):format(totalHit, totalMiss), C.INFO, 2.5)
    end,

    Verbose = function(on) CFG.VERBOSE = on and true or false end,
}

notify("v12 pronta", C.INFO, 2)
print([[
╔══════════════════════════════════════════════════╗
║  OUTSPAMMER v12                                  ║
╠══════════════════════════════════════════════════╣
║  [F1] SCRIPT ON/OFF    <- kill switch            ║
║  [F2] PANICO (para o spam)                       ║
║  [F3] VIM   [F4] TARGET   [F6] report            ║
║  [F7] PAUSA 3s (fugir)  [F8] PAUSA 10s           ║
╠══════════════════════════════════════════════════╣
║  VOA -> o script detecta e para sozinho          ║
║  Pousa -> retoma automaticamente                 ║
╠══════════════════════════════════════════════════╣
║  Aperta Q -> spamma SO o Q                       ║
║  Aperta R -> desliga Q, spamma SO o R            ║
╠══════════════════════════════════════════════════╣
║  Spam.FlyInfo()   diagnostico do voo             ║
║  Spam.Pause(5)    Spam.Resume()                  ║
║  Spam.Range(60)   Spam.Targets()  Spam.Test("R") ║
╚══════════════════════════════════════════════════╝
]])
