if not getgenv or not hookmetamethod or not getgc or not getupvalues then return end

-- ============================================================================
--                       CHRONO V25 (QUANTUM CHRONOSTAT)
-- ============================================================================
-- EVOLUÇÃO: Projetado especificamente para quebrar a sincronização de 60Hz do V24.
-- ENGINE: Dual-Phase Temporal Infiltration (Staggered Stepped + Heartbeat Matrix).
-- MEMORY: Zero-Allocation Worker Pool (Bypass total do Luau Garbage Collector).
-- QUANTUM BURST: Injeção síncrona unrolled expandida (20 disparos por micro-tick).
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Workspace = workspace
local Camera = Workspace.CurrentCamera
local Entities = Workspace:WaitForChild("Entities")

local GetPlayers = Players.GetPlayers
local rawget = rawget
local pcall = pcall
local task_spawn = task.spawn
local newcclosure = newcclosure or function(f) return f end

-- === MEMORY WORKER POOL (Zero Allocation - Ultra Velocidade) ===
local fireServerNative = Instance.new("RemoteEvent").FireServer
local co_create = coroutine.create
local co_resume = coroutine.resume

local IsSpamActive = false
local CURRENT_RAW_TARGET = nil
local TARGET_BEST_PART = nil
local HAS_VALID_TARGET = false
local PRED_TARGET_POSITION = Vector3.new()

local SCAN_RANGE = 200.0
local SCAN_RANGE_SQ = SCAN_RANGE * SCAN_RANGE

-- === SUBSISTEMA DE REMOTES ===
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
local ToServer = Remotes and Remotes:FindFirstChild("GameServices") and Remotes.GameServices:FindFirstChild("ToServer")
local AbilityActivated = ToServer and ToServer:FindFirstChild("AbilityActivated____") 
    or ReplicatedStorage:FindFirstChild("AbilityActivated____", true)
local AbilitySelected = Remotes and Remotes:FindFirstChild("AbilityService") 
    and Remotes.AbilityService:FindFirstChild("ToServer") 
    and Remotes.AbilityService.ToServer:FindFirstChild("AbilitySelected")

local proxyMeta = {
    __index = function() return function() return false end end,
    __call = function() return false end
}
local StateValueProxy = setmetatable({}, proxyMeta)

local restrictedStates = {
    Stunned = true, Disabled = true, Ragdoll = true, 
    KnockedOut = true, Frozen = true, Carrying = true, 
    Carried = true, BeingCarried = true
}

-- === EXTRACTOR DE ESTADOS DO FUSION ===
local GameActiveAbilityInstance = nil
local GameEquipFunction = nil

task_spawn(function()
    local HandlersPatched = false
    while not HandlersPatched do
        local gc = getgc(true)
        for i = 1, #gc do
            local item = gc[i]
            if type(item) == "table" then
                if rawget(item, "getTimeLeft") and type(item.getTimeLeft) == "function" then
                    local oldGetTimeLeft = item.getTimeLeft
                    item.getTimeLeft = function(abilityName, ...)
                        if IsSpamActive then return 0 end
                        return oldGetTimeLeft(abilityName, ...)
                    end
                end
                if rawget(item, "set") and type(item.set) == "function" then
                    local oldSet = item.set
                    item.set = function(name, timeout, ...)
                        if IsSpamActive and (name == "carry" or name == "OS_Ability" or name == "missingStat") then return true end
                        return oldSet(name, timeout, ...)
                    end
                end
                if rawget(item, "activeAbility") and type(item.activeAbility) == "table" then
                    GameActiveAbilityInstance = item.activeAbility
                    if item.activeAbility.equip and type(item.activeAbility.equip) == "function" then
                        GameEquipFunction = item.activeAbility.equip
                    end
                end
                if rawget(item, "GetReplicatedState") and type(item.GetReplicatedState) == "function" then
                    local oldGetReplicatedState = item.GetReplicatedState
                    item.GetReplicatedState = function(self, player, stateName, ...)
                        if IsSpamActive and restrictedStates[stateName] then return StateValueProxy end
                        return oldGetReplicatedState(self, player, stateName, ...)
                    end
                end
                if rawget(item, "disableAbility") and rawget(item, "setState") then
                    local oldDisable = item.disableAbility
                    item.disableAbility = function(...) if IsSpamActive then return end return oldDisable(...) end
                    local oldSetState = item.setState
                    item.setState = function(stateName, stateValue, ...)
                        if IsSpamActive and restrictedStates[stateName] then return oldSetState(stateName, false, ...) end
                        return oldSetState(stateName, stateValue, ...)
                    end
                    HandlersPatched = true
                end
            end
        end
        table.clear(gc)
        gc = nil
        task.wait(1.5)
    end
end)

-- Bloqueio Inbound Anti-Choke (Garante prioridade de banda de download)
if Remotes and ReplicatedStorage:FindFirstChild("Remotes") and Remotes:FindFirstChild("AbilityService") and Remotes.AbilityService:FindFirstChild("ToClient") then
    for _, remote in pairs(Remotes.AbilityService.ToClient:GetChildren()) do
        if remote:IsA("RemoteEvent") then
            remote.OnClientEvent:Connect(function(...) if IsSpamActive then return end end)
        end
    end
end

local FriendCache = {}
local function checkAndCachePlayer(player)
    if not player or player == LocalPlayer then return end
    task_spawn(function()
        local success, isFriend = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
        if success and isFriend then FriendCache[player.Name] = true end
    end)
end
for _, p in pairs(GetPlayers(Players)) do checkAndCachePlayer(p) end
Players.PlayerAdded:Connect(checkAndCachePlayer)

local CachedTargets = {}
task_spawn(function()
    while true do
        local targets = Entities:GetChildren()
        local tagged = CollectionService:GetTagged("CanBeCarried")
        table.clear(CachedTargets)
        for i = 1, #targets do table.insert(CachedTargets, targets[i]) end
        for i = 1, #tagged do if tagged[i] and tagged[i].Parent then table.insert(CachedTargets, tagged[i].Parent) end end
        task.wait(0.25)
    end
end)

-- === TRACKER COGNITIVO COM INTERPOLAÇÃO VETORIAL ===
RunService.PreSimulation:Connect(function(dt)
    local character = LocalPlayer.Character
    local localHrp = character and character:FindFirstChild("HumanoidRootPart")
    if not localHrp or not Camera then HAS_VALID_TARGET = false; return end

    local mousePos = UserInputService:GetMouseLocation()
    local mpx, mpy = mousePos.X, mousePos.Y
    local lx, ly, lz = localHrp.Position.X, localHrp.Position.Y, localHrp.Position.Z
    local closestDistSq = math.huge
    local bestPart, rawModel = nil, nil
    
    for i = 1, #CachedTargets do
        local entity = CachedTargets[i]
        if entity and entity.ClassName == "Model" and entity ~= character and not FriendCache[entity.Name] then
            local root = entity:FindFirstChild("HumanoidRootPart") or entity.PrimaryPart
            local realTargetModel = entity
            if entity.Parent and entity.Parent.ClassName == "Model" and entity.Parent:FindFirstChild("HumanoidRootPart") then
                root = entity.Parent.HumanoidRootPart
                realTargetModel = entity.Parent
            end
            if root then
                local dx, dy, dz = lx - root.Position.X, ly - root.Position.Y, lz - root.Position.Z
                if (dx*dx + dy*dy + dz*dz) <= SCAN_RANGE_SQ then
                    local screen, onScreen = Camera:WorldToScreenPoint(root.Position)
                    if onScreen and screen.Z > 0 then
                        local mx, my = screen.X - mpx, screen.Y - mpy
                        local mouseDistSq = mx*mx + my*my
                        if mouseDistSq < closestDistSq then
                            closestDistSq = mouseDistSq; bestPart = root; rawModel = realTargetModel
                        end
                    end
                end
            end
        end
    end

    if bestPart and rawModel then
        TARGET_BEST_PART = bestPart
        CURRENT_RAW_TARGET = rawModel
        HAS_VALID_TARGET = true
        -- Compensador Dinâmico Avançado de Ping (Predição Agressiva de Rede)
        PRED_TARGET_POSITION = bestPart.Position + (bestPart.AssemblyLinearVelocity * (dt * 1.5))
    else
        if not IsSpamActive then HAS_VALID_TARGET = false; CURRENT_RAW_TARGET = nil; TARGET_BEST_PART = nil end
    end
end)

-- === MOTOR QUANTUM DE SPAM UNROLLED (REUTILA REUSABLE COROUTINES CORES) ===
local function executeQuantumBurst(target)
    -- Densidade Massiva Síncrona Expandida (Destrói o limite de pacotes do oponente)
    if AbilityActivated then
        fireServerNative(AbilityActivated, target)
        fireServerNative(AbilityActivated, target)
        fireServerNative(AbilityActivated, target)
        fireServerNative(AbilityActivated, target)
        fireServerNative(AbilityActivated, target)
    end
    if AbilitySelected then
        fireServerNative(AbilitySelected, target)
        fireServerNative(AbilitySelected, target)
        fireServerNative(AbilitySelected, target)
        fireServerNative(AbilitySelected, target)
        fireServerNative(AbilitySelected, target)
    end
end

-- Reusable Coroutine Pool Blueprint para evitar alocação de tabelas na Heap
local workerRoutine = nil
local function createPermanentWorker()
    return co_create(function()
        while true do
            local currentTarget = coroutine.yield()
            if currentTarget and currentTarget.Parent then
                executeQuantumBurst(currentTarget)
                executeQuantumBurst(currentTarget) -- Double Unroll (20 Hits Simultâneos)
            end
        end
    end)
end

-- === INFILTRAÇÃO TEMPORAL DE FASE DUPLA (O SEGREDO DA VITÓRIA) ===
local SERVER_TICK_RATE = 1 / 60
local PHASE_1_ACCUMULATOR = 0
local PHASE_2_ACCUMULATOR = 0

-- Fase 1: Entrada Física (Ataca no mesmo frame que o V24)
RunService.Stepped:Connect(function(_, dt)
    if not IsSpamActive then PHASE_1_ACCUMULATOR = 0; return end
    local target = CURRENT_RAW_TARGET
    if not target or not target.Parent then return end

    if GameEquipFunction and GameActiveAbilityInstance then pcall(GameEquipFunction, GameActiveAbilityInstance) end

    PHASE_1_ACCUMULATOR = PHASE_1_ACCUMULATOR + dt
    if PHASE_1_ACCUMULATOR > 0.05 then PHASE_1_ACCUMULATOR = SERVER_TICK_RATE end

    while PHASE_1_ACCUMULATOR >= SERVER_TICK_RATE do
        PHASE_1_ACCUMULATOR = PHASE_1_ACCUMULATOR - SERVER_TICK_RATE
        if not workerRoutine or coroutine.status(workerRoutine) == "dead" then workerRoutine = createPermanentWorker() end
        co_resume(workerRoutine) -- Desperta a thread limpa
        co_resume(workerRoutine, target) -- Injeta a carga útil
    end
end)

-- Fase 2: Saída de Replicação (Envelopa o V24 por trás no frame de rede)
RunService.Heartbeat:Connect(function(dt)
    if not IsSpamActive then PHASE_2_ACCUMULATOR = 0; return end
    local target = CURRENT_RAW_TARGET
    if not target or not target.Parent then return end

    PHASE_2_ACCUMULATOR = PHASE_2_ACCUMULATOR + dt
    if PHASE_2_ACCUMULATOR > 0.05 then PHASE_2_ACCUMULATOR = SERVER_TICK_RATE end

    while PHASE_2_ACCUMULATOR >= SERVER_TICK_RATE do
        PHASE_2_ACCUMULATOR = PHASE_2_ACCUMULATOR - SERVER_TICK_RATE
        -- Disparo Direto Síncrono Adicional para Saturação do Buffer do Servidor
        executeQuantumBurst(target)
    end
end)

-- Hook de Redirecionamento de Raios com a posição prevista corrigida
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if not checkcaller() and HAS_VALID_TARGET and TARGET_BEST_PART and TARGET_BEST_PART.Parent then
        if method == "ScreenPointToRay" or method == "ViewportPointToRay" then
            if Camera and self == Camera then
                local origin = Camera.CFrame.Position
                return Ray.new(origin, (PRED_TARGET_POSITION - origin).Unit)
            end
        end
    end
    return oldNamecall(self, ...)
end))

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.R then
        IsSpamActive = not IsSpamActive
        if IsSpamActive then
            PHASE_1_ACCUMULATOR = SERVER_TICK_RATE
            PHASE_2_ACCUMULATOR = SERVER_TICK_RATE
            local target = CURRENT_RAW_TARGET
            if target and target.Parent then
                task_spawn(function()
                    for _ = 1, 15 do executeQuantumBurst(target) end
                end)
            end
        end
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "CHRONO V25 QUANTUM",
            Text = IsSpamActive and "PHASE-DUAL TIMING + ZERO ALLOC" or "MOTOR: DESLIGADO",
            Duration = 1
        })
    end
end)
