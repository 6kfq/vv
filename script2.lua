if not getgenv or not hookmetamethod or not getgc or not getupvalues then return end

-- === PONTEIROS DE SUBSISTEMA NATIVO C-SIDE ===
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
local PlayerFromCharacter = Players.GetPlayerFromCharacter
local WorldToScreen = Camera.WorldToScreenPoint
local GetMouseLocation = UserInputService.GetMouseLocation

local math_huge = math.huge
local rawget = rawget
local pcall = pcall
local task_spawn = task.spawn
local task_wait = task.wait
local newcclosure = newcclosure or function(f) return f end

-- === REGISTRADORES GLOBAIS DE ESTADO ===
local IsSpamActive = false
local CURRENT_RAW_TARGET = nil
local TARGET_BEST_PART = nil
local HAS_VALID_TARGET = false

local SCAN_RANGE = 120.0
local SCAN_RANGE_SQ = SCAN_RANGE * SCAN_RANGE

local RANGE_LIMIT = 65.0
local RANGE_LIMIT_SQ = RANGE_LIMIT * RANGE_LIMIT

-- === CAPTURA DE ESCOPO DO JOGO (EXTRAÇÃO DE ARQUIVOS INTERNOS) ===
local GameActiveAbilityInstance = nil
local GameEquipFunction = nil
local GameTargetSystemInstance = nil

-- CAPTURA DE ESCOPO COM ZERO FREEZE (CORREÇÃO PARA ANULAR O 0 FPS NA INJEÇÃO)
task_spawn(function()
    task.wait(2)
    local HitscanFound = false
    local CarryBypassFound = false
    
    local gc = getgc(true)
    local gcLength = #gc
    
    for i = 1, gcLength do
        if i % 1000 == 0 then 
            task.wait() 
        end
        
        local item = gc[i]
        if type(item) == "table" then
            if not GameActiveAbilityInstance and rawget(item, "activeAbility") and type(item.activeAbility) == "table" then
                local targetAbility = item.activeAbility
                if targetAbility.equip and type(targetAbility.equip) == "function" then
                    GameActiveAbilityInstance = targetAbility
                    GameEquipFunction = targetAbility.equip
                end
            end
            if not GameTargetSystemInstance and (rawget(item, "getTarget") or rawget(item, "GetClosestTarget")) then
                GameTargetSystemInstance = item
            end
            
            if not CarryBypassFound and rawget(item, "set") and rawget(item, "isAlive") and rawget(item, "kill") then
                local oldSet = item.set
                item.set = function(name, timeout)
                    if IsSpamActive and name == "carry" then return true end
                    return oldSet(name, timeout)
                end
                CarryBypassFound = true
            end

            if not HitscanFound and rawget(item, "Hitscan") and rawget(item, "AreaCheck") and not rawget(item, "CreateTargetProximityPrompt") then
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
            
        elseif type(item) == "function" and not isexecutorclosure(item) then
            local success, upvals = pcall(getupvalues, item)
            if success and type(upvals) == "table" then
                for _, upv in pairs(upvals) do
                    if type(upv) == "table" and rawget(upv, "activeAbility") then
                        local targetAbility = upv.activeAbility
                        if type(targetAbility) == "table" and targetAbility.equip then
                            GameActiveAbilityInstance = targetAbility
                            GameEquipFunction = targetAbility.equip
                        end
                    end
                end
            end
        end
    end
    
    table.clear(gc)
    gc = nil
end)

-- === SISTEMA DE CACHE AMIGÁVEL ===
local FriendCache = {}
local function checkAndCachePlayer(player)
    if not player or player == LocalPlayer then return end
    task_spawn(function()
        local success, isFriend = pcall(function()
            return LocalPlayer:IsFriendsWith(player.UserId)
        end)
        if success and isFriend then FriendCache[player.Name] = true end
    end)
end
local allPlayers = GetPlayers(Players)
for i = 1, #allPlayers do checkAndCachePlayer(allPlayers[i]) end
Players.PlayerAdded:Connect(checkAndCachePlayer)

-- === COMPONENTES DE REDE DE SUBSISTEMA ===
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local ToServer = Remotes and Remotes:FindFirstChild("GameServices") and Remotes.GameServices:FindFirstChild("ToServer")
local AbilityActivated = ToServer and ToServer:FindFirstChild("AbilityActivated____") or ReplicatedStorage:FindFirstChild("AbilityActivated____", true)
local fireAbility = AbilityActivated and AbilityActivated.FireServer

-- === CACHE FRACIONADO DE ENTIDADES ===
local CachedTargets = {}
task_spawn(function()
    while true do
        local targets = Entities:GetChildren()
        local tagged = CollectionService:GetTagged("CanBeCarried")
        
        table.clear(CachedTargets)
        for i = 1, #targets do table.insert(CachedTargets, targets[i]) end
        for i = 1, #tagged do 
            if tagged[i] and tagged[i].Parent then
                table.insert(CachedTargets, tagged[i].Parent) 
            end
        end
        task.wait(0.3)
    end
end)

-- === MENTE 1: RASTREAMENTO COGNITIVO COM ANTECIPAÇÃO ===
local currentDistanceSq, mx, my, mouseDistSq
local dx, dy, dz

RunService.PreSimulation:Connect(function()
    local character = LocalPlayer.Character
    local localHrp = character and character:FindFirstChild("HumanoidRootPart")

    if not localHrp or not Camera then
        HAS_VALID_TARGET = false; CURRENT_RAW_TARGET = nil; TARGET_BEST_PART = nil; return
    end

    local mousePos = GetMouseLocation(UserInputService)
    local mpx, mpy = mousePos.X, mousePos.Y
    local lx, ly, lz = localHrp.Position.X, localHrp.Position.Y, localHrp.Position.Z
    
    local closestDistSq = math_huge
    local bestPart = nil
    local rawModel = nil
    
    for i = 1, #CachedTargets do
        local entity = CachedTargets[i]
        if entity and entity.ClassName == "Model" and entity ~= character then
            local targetName = entity.Name
            local targetPlayer = Players:FindFirstChild(targetName)
            
            if not (targetPlayer and FriendCache[targetName]) then
                local root = entity:FindFirstChild("HumanoidRootPart") or entity.PrimaryPart
                local realTargetModel = entity
                local entityParent = entity.Parent
                if entityParent ~= workspace and entityParent ~= Entities then
                    if entityParent.ClassName == "Model" and entityParent:FindFirstChild("HumanoidRootPart") then
                        root = entityParent.HumanoidRootPart
                        realTargetModel = entityParent
                    end
                end
                
                if root then
                    dx = lx - root.Position.X; dy = ly - root.Position.Y; dz = lz - root.Position.Z
                    currentDistanceSq = (dx*dx + dy*dy + dz*dz)
                    
                    if currentDistanceSq <= SCAN_RANGE_SQ then
                        local screen, onScreen = Camera:WorldToScreenPoint(root.Position)
                        if onScreen and screen.Z > 0 then
                            mx = screen.X - mpx; my = screen.Y - mpy
                            mouseDistSq = mx*mx + my*my
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

-- === MENTE 2: MOTOR V10 SOLID-STATE MATRIX ===
local networkTrigger = fireAbility or (AbilityActivated and AbilityActivated.FireServer)

local lastSendTime = os.clock()
local ACCUMULATOR = 0

-- CONSTANTES ESTÁTICAS PURAS (Aceleração Máxima Superior ao V8)
local FORCED_RATE = 110        -- Taxa de ciclos elevada (V8 usa 95)
local TIME_STEP = 1 / FORCED_RATE

-- Otimização de Upvalue: Ponteiro direto na stack de memória para velocidade extrema
local function fireNetworkOnly(target)
    if networkTrigger and AbilityActivated then
        pcall(networkTrigger, AbilityActivated, target)
    end
end

-- Super Matriz Industrial Desenrolada (10 hits puros síncronos)
local function executeSolidMatrix(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
    fireNetworkOnly(target)
end

-- ENGINE SÍNCRONA DE FLUXO DIRETO (ZERO OVERHEAD DE COROUTINE)
local function executeMatrixDischarge()
    if not IsSpamActive or not CURRENT_RAW_TARGET or not CURRENT_RAW_TARGET.Parent then 
        ACCUMULATOR = 0
        return 
    end
    
    local currentTarget = CURRENT_RAW_TARGET
    local currentTime = os.clock()
    local deltaTime = currentTime - lastSendTime
    lastSendTime = currentTime

    if deltaTime > 0.1 then deltaTime = 0.016 end 
    
    ACCUMULATOR = ACCUMULATOR + deltaTime

    -- O SEGREDO DO V10: Remoção completa do task_spawn.
    -- O loop consome o acumulador e executa os 10 hits diretamente na thread nativa do PreSimulation.
    -- Isso atropela a fila de agendamento do V8, entregando os pacotes de forma instantânea.
    while ACCUMULATOR >= TIME_STEP do
        ACCUMULATOR = ACCUMULATOR - TIME_STEP
        executeSolidMatrix(currentTarget)
    end
end

-- CONTROLADOR VISUAL TOTALMENTE ISOLADO
local function executeVisualOverdrive()
    if IsSpamActive and CURRENT_RAW_TARGET and CURRENT_RAW_TARGET.Parent then
        if GameEquipFunction and GameActiveAbilityInstance then
            pcall(GameEquipFunction, GameActiveAbilityInstance, CURRENT_RAW_TARGET)
        end
    end
end

-- ESTABILIZAÇÃO RÍGIDA DE HITBOX V10
RunService.Heartbeat:Connect(function()
    if IsSpamActive and CURRENT_RAW_TARGET and TARGET_BEST_PART then
        local character = LocalPlayer.Character
        local localHrp = character and character:FindFirstChild("HumanoidRootPart")
        if localHrp then
            local direction = (TARGET_BEST_PART.Position - localHrp.Position).Unit
            localHrp.AssemblyLinearVelocity = localHrp.AssemblyLinearVelocity + (direction * 0.06)
        end
    end
end)

-- === PIPELINE DE AGENDAMENTO MATRICIAL V10 ===
RunService.PreRender:Connect(executeVisualOverdrive) 
RunService.PreSimulation:Connect(executeMatrixDischarge)


-- === HOOK METAMETÓDICO NATIVO ===
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

-- === INTERFACE INTERATIVA ===
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.R then
        IsSpamActive = not IsSpamActive
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "CHRONO V5 STABLE",
            Text = IsSpamActive and "MOTOR LATÊNCIA ZERO ATIVO10" or "MOTOR: DESLIGADO",
            Duration = 1
        })
    end
end)
