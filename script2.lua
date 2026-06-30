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

-- CAPTURA DE ESCOPO AMORTECIDA (ZERO FREEZE / ANULA O 0 FPS)
task_spawn(function()
    task.wait(1) -- Aguarda o jogo estabilizar após a injeção
    
    local HitscanFound = false
    local CarryBypassFound = false

    while not (GameActiveAbilityInstance and GameEquipFunction and HitscanFound) do
        local gc = getgc(true)
        
        for i = 1, #gc do
            -- A cada 5000 itens verificados, damos uma pausa de 1 micro-tick (1 frame)
            -- Isso faz com que o jogo continue rodando liso e não congele em 0 FPS
            if i % 5000 == 0 then 
                task.wait() 
            end
            
            local item = gc[i]
            if type(item) == "table" then
                -- 1. Captura da Habilidade do Soco (SuperPunch)
                if not GameActiveAbilityInstance and rawget(item, "activeAbility") and type(item.activeAbility) == "table" then
                    local targetAbility = item.activeAbility
                    if targetAbility.equip and type(targetAbility.equip) == "function" then
                        GameActiveAbilityInstance = targetAbility
                        GameEquipFunction = targetAbility.equip
                    end
                end
                if rawget(item, "getTarget") or rawget(item, "GetClosestTarget") then
                    GameTargetSystemInstance = item
                end
                
                -- 2. Interceptador de Debounce unificado
                if not CarryBypassFound and rawget(item, "set") and rawget(item, "isAlive") and rawget(item, "kill") then
                    local oldSet = item.set
                    item.set = function(name, timeout)
                        if IsSpamActive and name == "carry" then return true end
                        return oldSet(name, timeout)
                    end
                    CarryBypassFound = true
                end

                -- 3. Injeção do Hitscan unificada
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
        
        if not (GameActiveAbilityInstance and GameEquipFunction and HitscanFound) then
            task.wait(1) -- Se não achou tudo, espera 1 segundo antes de reescanear a memória
        end
    end
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

-- === CACHE FRACIONADO DE ENTIDADES (ALÍVIO DE FRAME) ===
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
        task.wait(0.3) -- Atualiza a lista 3 vezes por segundo fora dos frames visuais
    end
end)

-- === MENTE 1: RASTREAMENTO COGNITIVO COM ANTECIPAÇÃO ===
local currentDistanceSq, mx, my, mouseDistSq
local dx, dy, dz

RunService.PreSimulation:Connect(function()
    local character = LocalPlayer.Character
    local localHrp = character and character:FindFirstChild("HumanoidRootPart")

    if not localHrp or not Camera then
        HAS_VALID_TARGET = false
        CURRENT_RAW_TARGET = nil
        TARGET_BEST_PART = nil
        return
    end

    local mousePos = GetMouseLocation(UserInputService)
    local mpx, mpy = mousePos.X, mousePos.Y
    local localHrpPos = localHrp.Position
    local lx, ly, lz = localHrpPos.X, localHrpPos.Y, localHrpPos.Z
    
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
                    local rootPos = root.Position
                    dx = lx - rootPos.X
                    dy = ly - rootPos.Y
                    dz = lz - rootPos.Z
                    currentDistanceSq = (dx*dx + dy*dy + dz*dz)
                    
                    if currentDistanceSq <= SCAN_RANGE_SQ then
                        local screen, onScreen = Camera:WorldToScreenPoint(rootPos)
                        
                        if onScreen and screen.Z > 0 then
                            mx = screen.X - mpx
                            my = screen.Y - mpy
                            mouseDistSq = mx*mx + my*my
                            
                            if mouseDistSq < closestDistSq then
                                closestDistSq = mouseDistSq
                                bestPart = root
                                rawModel = realTargetModel
                            end
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
    else
        if not IsSpamActive then
            HAS_VALID_TARGET = false
            CURRENT_RAW_TARGET = nil
            TARGET_BEST_PART = nil
        end
    end
end)

-- === MENTE 2: MOTOR PHYSICAL SYNC ALIGN ===
local PHYSICAL_MULTIPLIER = 6 -- Ajuste fino para vazão máxima sem atrasar o ping
local VISUAL_MULTIPLIER = 3   

local networkTrigger = fireAbility or (AbilityActivated and AbilityActivated.FireServer)

local function fireNetworkOnly(target)
    if networkTrigger and AbilityActivated then
        networkTrigger(AbilityActivated, target)
    end
end

local function fireVisualWithEquip(target)
    if GameEquipFunction and GameActiveAbilityInstance then
        pcall(GameEquipFunction, GameActiveAbilityInstance, target)
    end
    if networkTrigger and AbilityActivated then
        networkTrigger(AbilityActivated, target)
    end
end

-- DISPARADOR COM ALINHAMENTO DE SIMULAÇÃO
local function executePhysicalDischarge()
    if IsSpamActive and CURRENT_RAW_TARGET and CURRENT_RAW_TARGET.Parent then
        local currentTarget = CURRENT_RAW_TARGET
        
        -- Força a thread a alinhar perfeitamente com a timeline de simulação física do Roblox
        task.synchronize() 
        
        for _ = 1, PHYSICAL_MULTIPLIER do
            task.defer(fireNetworkOnly, currentTarget)
        end
    end
end

local function executeVisualDischarge()
    if IsSpamActive and CURRENT_RAW_TARGET and CURRENT_RAW_TARGET.Parent then
        local currentTarget = CURRENT_RAW_TARGET
        for _ = 1, VISUAL_MULTIPLIER do
            fireVisualWithEquip(currentTarget)
        end
    end
end

-- ESTABILIZAÇÃO DE VELOCIDADE DA HITBOX
RunService.Heartbeat:Connect(function()
    if IsSpamActive and CURRENT_RAW_TARGET and TARGET_BEST_PART then
        local character = LocalPlayer.Character
        local localHrp = character and character:FindFirstChild("HumanoidRootPart")
        if localHrp then
            local direction = (TARGET_BEST_PART.Position - localHrp.Position).Unit
            localHrp.AssemblyLinearVelocity = localHrp.AssemblyLinearVelocity + (direction * 0.04)
        end
    end
end)

-- === PIPELINE DE AGENDAMENTO SIMULADO ===
RunService.PreRender:Connect(executeVisualDischarge)
RunService.PreSimulation:Connect(executePhysicalDischarge)
RunService.PostSimulation:Connect(executePhysicalDischarge)
RunService.Heartbeat:Connect(executePhysicalDischarge)

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
            Title = "CHRONO QUANTUM 12.0",
            Text = IsSpamActive and "MODO QUANTUM + VELOCITY ATIVO" or "MOTOR: DESLIGADO",
            Duration = 1
        })
    end
end)nameBox.Parent = frame

local applyBtn = Instance.new("TextButton")
applyBtn.Text = "Aplicar"
applyBtn.Size = UDim2.new(1, -20, 0, 30)
applyBtn.Position = UDim2.new(0, 10, 0, 115)
applyBtn.Parent = frame

-- ===== FUNÇÕES =====

local function getTarget()
	if not targetUserId then return nil end
	return Players:GetPlayerByUserId(targetUserId)
end

local function replaceText(text, plr)
	if not text or not plr then return text end
	text = string.gsub(text, plr.Name, replacement)
	text = string.gsub(text, plr.DisplayName, replacement)
	return text
end

local function hook(obj, plr)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
		
		-- aplica na hora
		obj.Text = replaceText(obj.Text, plr)

		-- aplica sempre que mudar
		obj:GetPropertyChangedSignal("Text"):Connect(function()
			obj.Text = replaceText(obj.Text, plr)
		end)
	end
end

local function applyNow()
	local plr = getTarget()
	if not plr then return end

	for _, obj in ipairs(game:GetDescendants()) do
		hook(obj, plr)
	end
end

-- botão
applyBtn.MouseButton1Click:Connect(function()
	targetUserId = tonumber(idBox.Text)
	replacement = nameBox.Text
	applyNow()
end)

-- novos objetos
game.DescendantAdded:Connect(function(obj)
	local plr = getTarget()
	if plr then
		hook(obj, plr)
	end
end)
