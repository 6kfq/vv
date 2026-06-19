local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
StarterGui:SetCore("SendNotification", {
    Title = "aaaaaaaaa",
    Text = "AutoclickDetection desativado!",
    Duration = 3
})

local OldNamecall
OldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if method == "FireServer" and self == ReplicatedStorage.Remotes.GameServices.ToServer.AutoclickerDetected then
        return
    end
    return OldNamecall(self, ...)
end))
