if not getgenv or not hookmetamethod then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local IsSystemEnabled = true 

-- Configurações de Engenharia Estocástica Avançada (V182v)
local SETTINGS = {
    NetworkRangeBuffer = 67.0,     
    MaxAbsoluteVelocity = 45.0,    
    DefaultRunSpeed = 16.0,        
    BaseSubTickWindow = 0.005,    
    ExtrapolationFactor = 1.65,    
    MaxErrorTolerance = 3.5,
    MinKalmanGain = 0.45,          -- Limite inferior para alvos lineares
    MaxKalmanGain = 0.88           -- Limite superior para respostas a strafe abrupto
}

local TableClear = table.clear
local Vector3Zero = Vector3.new(0, 0, 0)
local MathHuge = math.huge

-- Alocação Estática de Memória (Anti-Garbage Collector)
local STATIC_PACKED_ARGS = {}
local KalmanPositions = {}
local LastVelocities = {}
local LastAccelerations = {}

local function notifySystemState(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 2,
            Button1 = "OK"
        })
    end)
end

-- Cache de Relacionamentos
local FriendCache = {}
local function checkAndCacheFriend(player)
    if player == LocalPlayer then return end
    task.defer(function()
        local success, isFriend = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
        FriendCache[player] = success and isFriend or false
    end)
end
for _, player in ipairs(Players:GetPlayers()) do checkAndCacheFriend(player) end
Players.PlayerAdded:Connect(checkAndCacheFriend)
Players.PlayerRemoving:Connect(function(player) FriendCache[player] = nil end)

-- Módulos do Jogo
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts", 10)
local ClientServices = PlayerScripts and PlayerScripts:WaitForChild("ClientServices", 10)
local AbilityClient = ClientServices and require(ClientServices:WaitForChild("AbilityClient"))
local AbilityManager = nil

pcall(function()
    for _, module in ipairs(ReplicatedStorage.ModuleScripts:GetChildren()) do
        if module:IsA("ModuleScript") and module.Name ~= "StateReplicator" and module.Name ~= "Data" then
            local data = require(module)
            if type(data) == "table" and data.canBeAffected then 
                AbilityManager = data 
                break 
            end
        end
    end
end)

local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local ToServer = Remotes and Remotes:FindFirstChild("ToServer")
local AbilityActivated = ToServer and ToServer:FindFirstChild("AbilityActivated____") or ReplicatedStorage:FindFirstChild("AbilityActivated____", true)

local SIGNATURE = {
    Learned = false,
    TargetIndex = 1, 
    CFrameIndex = 2,
    PosIndex = 3,
    TemplateArgs = nil
}

local function learnSignature(args)
    local hasModel = false
    for i, arg in ipairs(args) do
        local t = typeof(arg)
        if t == "Instance" and arg:IsA("Model") then
            SIGNATURE.TargetIndex = i; hasModel = true
        elseif t == "CFrame" then
            SIGNATURE.CFrameIndex = i
        elseif t == "Vector3" then
            SIGNATURE.PosIndex = i
        end
    end
    if hasModel then 
        SIGNATURE.TemplateArgs = {}
        for k, v in pairs(args) do STATIC_PACKED_ARGS[k] = v end
        SIGNATURE.Learned = true 
        notifySystemState("MATRIX V182v", "Assinatura Dinâmica Acoplada!")
    end
end

local COCKPIT_BUFFER = {
    Valid = false,
    Target = nil,
    Position = Vector3Zero,
    CFramePrimary = CFrame.identity
}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function checkLineOfSight(origin, targetPos, character, targetChar)
    raycastParams.FilterDescendantsInstances = {character, targetChar}
    local raycastResult = Workspace:Raycast(origin, targetPos - origin, raycastParams)
    return raycastResult == nil
end

-- ============================================================================
-- ⚡ MOTOR TELEMÉTRICO DE ALTA FREQUÊNCIA (RENDERSTEP)
-- ============================================================================
RunService:BindToRenderStep("MatrixV182vCore", Enum.RenderPriority.Input.Value - 4, function(dt)
    if not IsSystemEnabled or not AbilityActivated or not AbilityClient or not AbilityClient.getState() then 
        COCKPIT_BUFFER.Valid = false 
        return 
    end
    
    local character = LocalPlayer.Character
    local localHrp = character and character:FindFirstChild("HumanoidRootPart")
    if not localHrp then COCKPIT_BUFFER.Valid = false return end
    
    local localPos = localHrp.Position
    local currentPing = LocalPlayer:GetNetworkPing() or 0.03
    local frameTime = dt > 0 and dt or 0.016
    local lookAheadTime = ((currentPing * 0.45) + SETTINGS.BaseSubTickWindow + dt) * SETTINGS.ExtrapolationFactor
    
    local bestChar, bestPredictedPos = nil, nil
    local bestScore = -MathHuge
    local currentEquippedAbility = AbilityClient.getEquippedAbility()
    
    local currentTool = character:FindFirstChildOfClass("Tool")
    local baseWeaponRange = (currentTool and currentTool:FindFirstChild("Range") and currentTool.Range.Value) or 20.0
    local maxPredictionLimit = baseWeaponRange + SETTINGS.NetworkRangeBuffer
    
    local predictedOrigin = localPos + (localHrp.AssemblyLinearVelocity * currentPing * 0.80)
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not FriendCache[player] and player.Character then
            local char = player.Character
            local hrp = char:FindFirstChild("HumanoidRootPart")
            
            if hrp and char.Parent then
                if AbilityManager and currentEquippedAbility and not AbilityManager.canBeAffected(char, currentEquippedAbility) then 
                    continue 
                end
                
                local rawPos = hrp.Position
                local finalVelocity = hrp.AssemblyLinearVelocity
                
                if finalVelocity.Magnitude > SETTINGS.MaxAbsoluteVelocity then
                    finalVelocity = finalVelocity.Unit * SETTINGS.DefaultRunSpeed
                end
                
                -- Extração de Derivadas Puras (Série de Taylor 3ª Ordem)
                local lastVelocity = LastVelocities[char] or finalVelocity
                LastVelocities[char] = finalVelocity
                local currentAcceleration = (finalVelocity - lastVelocity) / frameTime
                
                local lastAcceleration = LastAccelerations[char] or currentAcceleration
                LastAccelerations[char] = currentAcceleration
                local currentJerk = (currentAcceleration - lastAcceleration) / frameTime
                
                -- FILTRO ESTOCÁSTICO ADAPTATIVO (O diferencial da V182v)
                local accelerationMagnitude = currentAcceleration.Magnitude
                local dynamicKalmanGain = math.clamp(SETTINGS.MaxKalmanGain - (accelerationMagnitude * 0.02), SETTINGS.MinKalmanGain, SETTINGS.MaxKalmanGain)
                
                local lastEstimatedPos = KalmanPositions[char] or rawPos
                local estimatedPos = lastEstimatedPos + dynamicKalmanGain * (rawPos - lastEstimatedPos)
                KalmanPositions[char] = estimatedPos
                
                local realDistance = (estimatedPos - localPos).Magnitude
                
                if realDistance <= maxPredictionLimit then
                    local translation = finalVelocity * lookAheadTime
                    local accelerationFactor = 0.5 * currentAcceleration * (lookAheadTime ^ 2)
                    local jerkFactor = (1/6) * currentJerk * (lookAheadTime ^ 3) * 0.20
                    
                    local predictedPos = estimatedPos + translation + accelerationFactor + jerkFactor
                    
                    -- Proteção contra anomalias de interpolação
                    if (predictedPos - estimatedPos).Magnitude > SETTINGS.MaxErrorTolerance then
                        predictedPos = estimatedPos + translation
                    end
                    
                    if checkLineOfSight(localPos, predictedPos, character, char) then
                        local score = (1000 - (predictedPos - localPos).Magnitude)
                        if score > bestScore then
                            bestScore = score
                            bestChar = char
                            bestPredictedPos = predictedPos
                        end
                    end
                end
            end
        end
    end
    
    if bestChar and bestPredictedPos then
        COCKPIT_BUFFER.Target = bestChar
        COCKPIT_BUFFER.Position = bestPredictedPos
        COCKPIT_BUFFER.CFramePrimary = CFrame.lookAt(predictedOrigin, bestPredictedPos)
        
        -- Table Pooling Estático (Substitui table.clone da V178v)
        TableClear(STATIC_PACKED_ARGS)
        if SIGNATURE.Learned and SIGNATURE.TemplateArgs then
            for k, v in pairs(SIGNATURE.TemplateArgs) do STATIC_PACKED_ARGS[k] = v end
            STATIC_PACKED_ARGS[SIGNATURE.TargetIndex] = bestChar
            STATIC_PACKED_ARGS[SIGNATURE.CFrameIndex] = COCKPIT_BUFFER.CFramePrimary
            STATIC_PACKED_ARGS[SIGNATURE.PosIndex] = bestPredictedPos
        else
            STATIC_PACKED_ARGS[1] = bestChar
            STATIC_PACKED_ARGS[2] = COCKPIT_BUFFER.CFramePrimary
            STATIC_PACKED_ARGS[3] = bestPredictedPos
        end
        COCKPIT_BUFFER.Valid = true
    else
        COCKPIT_BUFFER.Valid = false
    end
end)

-- ============================================================================
-- ⚡ PIPELINE DE INJEÇÃO EM FILA DE REDE (PRESIMULATION)
-- ============================================================================
RunService.PreSimulation:Connect(function()
    if not IsSystemEnabled or not COCKPIT_BUFFER.Valid then return end
    pcall(function() 
        AbilityActivated:FireServer(unpack(STATIC_PACKED_ARGS)) 
    end)
end)

-- ============================================================================
-- ⚡ SINCRONIZADOR FÍSICO LOCAL (HEARTBEAT)
-- ============================================================================
RunService.Heartbeat:Connect(function()
    if IsSystemEnabled and COCKPIT_BUFFER.Valid and COCKPIT_BUFFER.Target then
        local character = LocalPlayer.Character
        local tool = character and character:FindFirstChildOfClass("Tool")
        
        if tool then
            local localHrp = character:FindFirstChild("HumanoidRootPart")
            local targetHrp = COCKPIT_BUFFER.Target:FindFirstChild("HumanoidRootPart")
            
            if localHrp and targetHrp then
                local baseWeaponRange = (tool:FindFirstChild("Range") and tool.Range.Value) or 20.0
                local maximumTolerance = baseWeaponRange + SETTINGS.NetworkRangeBuffer
                
                if (localHrp.Position - targetHrp.Position).Magnitude <= maximumTolerance then
                    pcall(function() tool:Activate() end)
                end
            end
        end
    end
end)

-- Hookmetamethod Estático
if AbilityActivated then
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        if IsSystemEnabled and self == AbilityActivated and getnamecallmethod() == "FireServer" then
            local args = {...}
            if not SIGNATURE.Learned then learnSignature(args) end
            if COCKPIT_BUFFER.Valid then
                return oldNamecall(self, unpack(STATIC_PACKED_ARGS))
            end
        end
        return oldNamecall(self, ...)
    end)
end

-- Controle Operacional (Tecla R)
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.R then 
        IsSystemEnabled = not IsSystemEnabled
        notifySystemState("MATRIX CORE V182v", IsSystemEnabled and "ENGINE V182v: ATIVA" or "MODO MANUAL")
        if not IsSystemEnabled then COCKPIT_BUFFER.Valid = false end
    end
end)

Players.PlayerRemoving:Connect(function(player)
    if player.Character then 
        KalmanPositions[player.Character] = nil
        LastVelocities[player.Character] = nil
        LastAccelerations[player.Character] = nil
    end
end)

notifySystemState("MATRIX V182v", "SISTEMA ESTOCÁSTICO INTEGRADO [R]")
