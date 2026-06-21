local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local targetUserId = nil
local replacement = ""

-- ===== GUI =====
local gui = Instance.new("ScreenGui")
gui.Name = "NameChangerUI"
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 260, 0, 160)
frame.Position = UDim2.new(0, 50, 0, 120)
frame.BackgroundColor3 = Color3.fromRGB(25,25,25)
frame.Parent = gui
frame.Active = true
frame.Draggable = true

local title = Instance.new("TextLabel")
title.Text = "Name Changer"
title.Size = UDim2.new(1, 0, 0, 25)
title.BackgroundColor3 = Color3.fromRGB(40,40,40)
title.TextColor3 = Color3.new(1,1,1)
title.Parent = frame

local idBox = Instance.new("TextBox")
idBox.PlaceholderText = "UserId"
idBox.Size = UDim2.new(1, -20, 0, 30)
idBox.Position = UDim2.new(0, 10, 0, 35)
idBox.Parent = frame

local nameBox = Instance.new("TextBox")
nameBox.PlaceholderText = "Novo nome"
nameBox.Size = UDim2.new(1, -20, 0, 30)
nameBox.Position = UDim2.new(0, 10, 0, 75)
nameBox.Parent = frame

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
