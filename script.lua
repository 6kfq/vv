-- Força os valores na tela - Coins: 8115 | Moonstone: 25

local player = game:GetService("Players").LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Procura e altera os textos dos coins e moonstone
for _, obj in pairs(playerGui:GetDescendants()) do
    if obj:IsA("TextLabel") then
        if obj.Name == "MysticCoinAmount" then
            obj.Text = "8115"
            print("Coins alterado para 8115")
        elseif obj.Name == "MoonstoneAmount" then
            obj.Text = "25"
            print("Moonstone alterado para 25")
        end
    end
end

-- Tenta achar dentro de ScreenGuis também
for _, screenGui in pairs(playerGui:GetChildren()) do
    if screenGui:IsA("ScreenGui") then
        for _, obj in pairs(screenGui:GetDescendants()) do
            if obj:IsA("TextLabel") then
                if obj.Name == "MysticCoinAmount" then
                    obj.Text = "8115"
                elseif obj.Name == "MoonstoneAmount" then
                    obj.Text = "25"
                end
            end
        end
    end
end
