if not getgenv or not hookmetamethod or not getgc or not getupvalues then return end

-- ============================================================================
--                          CHRONO V23 NEXUS (THREAD HIJACKER)
-- ============================================================================
-- ANÁLISE: Supera o espelhamento idêntico manipulando o agendador de threads.
-- MOTOR: Pure Coroutine Resuming + Early Stepped Phase Injection.
-- OTIMIZAÇÃO: Zero alocação de memória dinâmica (Zero GC Pauses).
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

-- === PROVEDORES NATIVOS DO MOTOR (IGNORA TASK SCHEDULER) ===
local co_create = coroutine.create
local co_resume = coroutine.resume
local co_status = coroutine.status

-- === REGISTRADORES GLOBAIS DE ESTADO ===
local IsSpamActive = false
local CURRENT_RAW_TARGET = nil
local TARGET_BEST_PART = nil
local HAS_VALID_TARGET = false

local SCAN_RANGE = 120.0
local SCAN_RANGE_SQ = SCAN_RANGE * SCAN_RANGE
local RANGE_LIMIT = 65.0
local RANGE_LIMIT_SQ = RANGE_LIMIT * RANGE_LIMIT

-- === SUBSISTEMA DE REMOTES ===
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
local ToServer = Remotes and Remotes:FindFirstChild("GameServices") and Remotes.GameServices:FindFirstChild("ToServer")
local AbilityActivated = ToServer and ToServer:FindFirstChild("AbilityActivated____") 
    or ReplicatedStorage:FindFirstChild("AbilityActivated____", true)
local AbilitySelected = Remotes and Remotes:FindFirstChild("AbilityService") 
    and Remotes.AbilityService:FindFirstChild("ToServer") 
    and Remotes.AbilityService.ToServer:FindFirstChild("AbilitySelected")

local fireAbility = AbilityActivated and AbilityActivated.FireServer
local fireSelected = AbilitySelected and AbilitySelected.FireServer

-- Proxy para mascarar leituras do Fusion no StateReplicator
local proxyMeta = {}
proxyMeta.__index = function(self, key)
    if key == "get" or key == "Get" then
        return function() return false end
    end
    return function() return false end
end
proxyMeta.__call = function() return false end
local StateValueProxy = setmetatable({}, proxyMeta)

-- Lista estendida de imunidade
local restrictedStates = {
    Stunned = true, Disabled = true, Ragdoll = true, 
    KnockedOut = true, Frozen = true, Carrying = true, 
    Carried = true, BeingCarried = true
}

-- === ENGENHARIA REVERSA DE MEMÓRIA (GC EXTRATOR) ===
local GameActiveAbilityInstance = nil
local GameEquipFunction = nil

task_spawn(function()
    local HitscanFound = false
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
                        if IsSpamActive and (name == "carry" or name == "OS_Ability" or name == "missingStat") then 
                            return true 
                        end
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
                        if IsSpamActive and restrictedStates[stateName] then
                            return StateValueProxy
                        end
                        return oldGetReplicatedState(self, player, stateName, ...)
                    end
                end

                if rawget(item, "disableAbility") and rawget(item, "setState") then
                    local oldDisable = item.disableAbility
                    item.disableAbility = function(...) if IsSpamActive then return end return oldDisable(...) end
                    
                    local oldSetState = item.setState
                    item.setState = function(stateName, stateValue, ...)
                        if IsSpamActive and restrictedStates[stateName] then
                            return oldSetState(stateName, false, ...)
                        end
                        return oldSetState(stateName, stateValue, ...)
                    end
                    HandlersPatched = true
                end

                if not HitscanFound and rawget(item, "Hitscan") and rawget(item, "AreaCheck") then
                    local oldHitscan = item.Hitscan
                    item.Hitscan = function(p6, p7)
                        if HAS_VALID_TARGET and TARGET_BEST_PART and TARGET_BEST_PART.Parent and CURRENT_RAW_TARGET and CURRENT_RAW_TARGET.Parent and not p7 then
                            local localHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                            if localHrp and localHrp.Parent then
                                local p1 = TARGET_BEST_PART.Position
                                local p2 = localHrp.Position
                                local dx, dy, dz = p1.X - p2.X, p1.Y - p2.Y, p1.Z - p2.Z
                                if (dx*dx + dy*dy + dz*dz) <= RANGE_LIMIT_SQ then
                                    return CURRENT_RAW_TARGET, nil
                                end
                            end
                        end
                        return oldHitscan(p6, p7)
                    end
                    HitscanFound = true
                end
            end
        end
        table.clear(gc)
        gc = nil
        task.wait(1.5)
    end
end)

-- === CORTE DE REDE ASSÍNCRONO ===
if Remotes and Remotes:FindFirstChild("AbilityService") and Remotes.AbilityService:FindFirstChild("ToClient") then
    local ToClientFolder = Remotes.AbilityService.ToClient
    for _, remote in pairs(ToClientFolder:GetChildren()) do
        if remote:IsA("RemoteEvent") then
            remote.OnClientEvent:Connect(function(...)
                if IsSpamActive then return end
            end)
        end
    end
end

-- === CACHE DE ENTIDADES ESTÁTICO ===
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
        for i = 1, #tagged do 
            if tagged[i] and tagged[i].Parent then table.insert(CachedTargets, tagged[i].Parent) end
        end
        task.wait(0.25)
    end
end)

-- === RASTREAMENTO COGNITIVO ===
RunService.PreSimulation:Connect(function()
    local character = LocalPlayer.Character
    local localHrp = character and character:FindFirstChild("HumanoidRootPart")

    if not localHrp or not Camera then
        HAS_VALID_TARGET = false; CURRENT_RAW_TARGET = nil; TARGET_BEST_PART = nil; return
    end

    local mousePos = UserInputService:GetMouseLocation()
    local mpx, mpy = mousePos.X, mousePos.Y
    local lx, ly, lz = localHrp.Position.X, localHrp.Position.Y, localHrp.Position.Z
    
    local closestDistSq = math.huge
    local bestPart = nil
    local rawModel = nil
    
    for i = 1, #CachedTargets do
        local entity = CachedTargets[i]
        if entity and entity.ClassName == "Model" and entity ~= character then
            local targetName = entity.Name
            if not FriendCache[targetName] then
                local root = entity:FindFirstChild("HumanoidRootPart") or entity.PrimaryPart
                local realTargetModel = entity
                local entityParent = entity.Parent
                
                if entityParent ~= workspace and entityParent ~= Entities and entityParent.ClassName == "Model" and entityParent:FindFirstChild("HumanoidRootPart") then
                    root = entityParent.HumanoidRootPart
                    realTargetModel = entityParent
                end
                
                if root then
                    local dx = lx - root.Position.X
                    local dy = ly - root.Position.Y
                    local dz = lz - root.Position.Z
                    if (dx*dx + dy*dy + dz*dz) <= SCAN_RANGE_SQ then
                        local screen, onScreen = Camera:WorldToScreenPoint(root.Position)
                        if onScreen and screen.Z > 0 then
                            local mx = screen.X - mpx
                            local my = screen.Y - mpy 
                            local mouseDistSq = mx*mx + my*my
                            if mouseDistSq < closestDistSq then
                                closestDistSq = mouseDistSq; bestPart = root; rawModel = realTargetModel
                            end
                        end
                    end
                end
            end
        end
    end

    if bestPart and rawModel then
        TARGET_BEST_PART = bestPart; CURRENT_RAW_TARGET = rawModel; HAS_VALID_TARGET = true
    else
        if not IsSpamActive then HAS_VALID_TARGET = false; CURRENT_RAW_TARGET = nil; TARGET_BEST_PART = nil end
    end
end)

-- === MOTOR TEMPORAL NEXUS CONTROLLER ===
local lastSendTime = os.clock()
local ACCUMULATOR = 0

local FORCED_RATE = 160        
local TIME_STEP = 1 / FORCED_RATE

-- Desdobramento estático de alta velocidade (Zero pcall Overhead)
local function executeDirectUnroll(target)
    if fireAbility and AbilityActivated then
        fireAbility(AbilityActivated, target)
        fireAbility(AbilityActivated, target)
        fireAbility(AbilityActivated, target)
        fireAbility(AbilityActivated, target)
    end
    if fireSelected and AbilitySelected then
        fireSelected(AbilitySelected, target)
        fireSelected(AbilitySelected, target)
        fireSelected(AbilitySelected, target)
        fireSelected(AbilitySelected, target)
    end
end

-- REUSABLE COROUTINE POOL (Ignora completamente o atraso do Task Scheduler)
local ThreadWorkerPool = {}
local NextWorkerSlot = 1

local function setupNativeWorkers()
    for i = 1, 6 do
        ThreadWorkerPool[i] = co_create(function()
            while true do
                local activeTarget = coroutine.yield()
                if activeTarget and activeTarget.Parent then
                    executeDirectUnroll(activeTarget)
                end
            end
        end)
        co_resume(ThreadWorkerPool[i])
    end
end
setupNativeWorkers()

local function pushThroughCoroutines(target)
    local slot = ThreadWorkerPool[NextWorkerSlot]
    if not slot or co_status(slot) == "dead" then
        ThreadWorkerPool[NextWorkerSlot] = co_create(function()
            while true do
                local activeTarget = coroutine.yield()
                if activeTarget and activeTarget.Parent then executeDirectUnroll(activeTarget) end
            end
        end)
        slot = ThreadWorkerPool[NextWorkerSlot]
        co_resume(slot)
    end
    co_resume(slot, target)
    NextWorkerSlot = (NextWorkerSlot % 6) + 1
end

local function executeNexusEngine()
    if not IsSpamActive then 
        ACCUMULATOR = 0
        return 
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.PlatformStand then 
        humanoid.PlatformStand = false 
    end

    local target = CURRENT_RAW_TARGET
    if not target or not target.Parent then return end

    if GameEquipFunction and GameActiveAbilityInstance then
        pcall(GameEquipFunction, GameActiveAbilityInstance)
    end

    local currentTime = os.clock()
    local deltaTime = currentTime - lastSendTime
    lastSendTime = currentTime

    if deltaTime > 0.1 then deltaTime = 0.016 end 
    ACCUMULATOR = ACCUMULATOR + deltaTime

    local loopCap = 0
    while ACCUMULATOR >= TIME_STEP do
        ACCUMULATOR = ACCUMULATOR - TIME_STEP
        loopCap = loopCap + 1
        if loopCap > 6 then break end

        -- 1. Disparo Síncrono Imediato
        pushThroughCoroutines(target)

        -- 2. Intercalação Forçada Assíncrona Nativa (Co-rotina paralela em lote)
        local worker = ThreadWorkerPool[NextWorkerSlot]
        if worker and co_status(worker) ~= "dead" then
            co_resume(worker, target)
        end
    end
end

-- TRIPLE EVENT PIX INTERCEPTION: O V23 ganha injetando pacotes na fase Stepped (Pre-Physics)
RunService.Stepped:Connect(executeNexusEngine)
RunService.PreSimulation:Connect(executeNexusEngine)
RunService.PreRender:Connect(executeNexusEngine)

RunService.PreRender:Connect(function()
    if IsSpamActive and CURRENT_RAW_TARGET and CURRENT_RAW_TARGET.Parent then
        if GameEquipFunction and GameActiveAbilityInstance then
            pcall(GameEquipFunction, GameActiveAbilityInstance)
        end
    end
end)

-- === HOOK METAMETÓDICO ===
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if not checkcaller() and HAS_VALID_TARGET and TARGET_BEST_PART and TARGET_BEST_PART.Parent then
        if method == "ScreenPointToRay" or method == "ViewportPointToRay" then
            if Camera and self == Camera then
                local origin = Camera.CFrame.Position
                return Ray.new(origin, (TARGET_BEST_PART.Position - origin).Unit)
            end
        end
    end
    return oldNamecall(self, ...)
end))

-- === INTERFACE CONTROLLER ===
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.R then
        IsSpamActive = not IsSpamActive
        
        if IsSpamActive then
            ACCUMULATOR = TIME_STEP
            local target = CURRENT_RAW_TARGET
            if target and target.Parent then
                task_spawn(function()
                    for _ = 1, 10 do
                        if fireAbility and AbilityActivated then fireAbility(AbilityActivated, target) end
                        if fireSelected and AbilitySelected then fireSelected(AbilitySelected, target) end
                    end
                end)
            end
        end
        
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "CHRONO V23 NEXUS",
            Text = IsSpamActive and "MOTOR HIJACKER OPERANTE" or "MOTOR: DESLIGADO",
            Duration = 1
        })
    end
end)
