-- deepseek generate
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local playerGui = player:WaitForChild("PlayerGui")

local THROW_POWER = 300

-- ===== ScreenGui =====
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GrabToolUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Enabled = true
screenGui.Parent = playerGui

-- ===== 准星 =====
local crosshairFrame = Instance.new("Frame")
crosshairFrame.Name = "Crosshair"
crosshairFrame.Size = UDim2.fromScale(1, 1)
crosshairFrame.BackgroundTransparency = 1
crosshairFrame.Visible = false
crosshairFrame.Parent = screenGui

local function makeBar(size, pos, parent)
    local f = Instance.new("Frame")
    f.Size = size
    f.Position = pos
    f.BackgroundColor3 = Color3.new(1, 1, 1)
    f.BorderSizePixel = 0
    f.ZIndex = 2
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.new(0, 0, 0)
    stroke.Thickness = 1
    stroke.Parent = f
    f.Parent = parent
    return f
end

local dot = makeBar(UDim2.fromOffset(4, 4), UDim2.new(0.5, -2, 0.5, -2), crosshairFrame)
local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = dot

makeBar(UDim2.fromOffset(2, 8), UDim2.new(0.5, -1, 0.5, -18), crosshairFrame)
makeBar(UDim2.fromOffset(2, 8), UDim2.new(0.5, -1, 0.5, 10), crosshairFrame)
makeBar(UDim2.fromOffset(8, 2), UDim2.new(0.5, -18, 0.5, -1), crosshairFrame)
makeBar(UDim2.fromOffset(8, 2), UDim2.new(0.5, 10, 0.5, -1), crosshairFrame)

-- ===== 开关按钮 =====
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "FeatureToggle"
toggleBtn.Size = UDim2.fromOffset(72, 72)
toggleBtn.Position = UDim2.new(1, -90, 0, 100)
toggleBtn.BackgroundColor3 = Color3.fromRGB(80, 30, 30)
toggleBtn.BackgroundTransparency = 0.25
toggleBtn.Text = "抓取\nOFF"
toggleBtn.TextColor3 = Color3.new(1, 1, 1)
toggleBtn.TextScaled = true
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.BorderSizePixel = 0
toggleBtn.ZIndex = 10
toggleBtn.Parent = screenGui

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(1, 0)
btnCorner.Parent = toggleBtn

local btnStroke = Instance.new("UIStroke")
btnStroke.Color = Color3.new(1, 1, 1)
btnStroke.Thickness = 1
btnStroke.Transparency = 0.5
btnStroke.Parent = toggleBtn

-- ===== 状态 =====
local holding = false
local mainPart = nil
local lockedRotation = nil
local grabbedList = {}
local followConn = nil
local featureEnabled = false

local MOVE_THRESHOLD = 15
local TIME_THRESHOLD = 0.45
local MAX_PARTS = 40
local touchTracker = {}

local function pointInGui(pos, gui, pad)
    pad = pad or 0
    local ap = gui.AbsolutePosition
    local as = gui.AbsoluteSize
    return pos.X >= ap.X - pad and pos.X <= ap.X + as.X + pad
       and pos.Y >= ap.Y - pad and pos.Y <= ap.Y + as.Y + pad
end

local function updateToggleVisual()
    crosshairFrame.Visible = featureEnabled
    toggleBtn.Text = featureEnabled and "抓取\nON" or "抓取\nOFF"
    toggleBtn.BackgroundColor3 = featureEnabled
        and Color3.fromRGB(30, 30, 30)
        or Color3.fromRGB(80, 30, 30)
end

local function crosshairRay()
    local vp = camera.ViewportSize
    return camera:ViewportPointToRay(vp.X / 2, vp.Y / 2)
end

local function getTargetFromScreen(pos)
    local ray = camera:ViewportPointToRay(pos.X, pos.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {player.Character}
    local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
    return result and result.Instance
end

local function collectParts(target)
    local parts = {}
    local model = target:FindFirstAncestorOfClass("Model")
    if model and model ~= player.Character then
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") and not d.Anchored then
                table.insert(parts, d)
                if #parts >= MAX_PARTS then break end
            end
        end
    end
    if #parts == 0 then table.insert(parts, target) end
    return parts
end

local function pickMain(parts)
    local best = parts[1]
    local bestVol = best.Size.X * best.Size.Y * best.Size.Z
    for i = 2, #parts do
        local p = parts[i]
        local v = p.Size.X * p.Size.Y * p.Size.Z
        if v > bestVol then best = p; bestVol = v end
    end
    return best
end

local function getRoot()
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function startFollow()
    if followConn then followConn:Disconnect() end
    followConn = RunService.Heartbeat:Connect(function()
        if not (holding and mainPart and mainPart.Parent) then return end
        local root = getRoot()
        if not root then return end
        local holdPos = root.Position + root.CFrame.LookVector * 8 + Vector3.new(0, 5, 0)
        local mainCF = CFrame.new(holdPos) * lockedRotation
        for _, item in ipairs(grabbedList) do
            if item.part.Parent then
                local targetCF = mainCF * item.offset
                item.bp.Position = targetCF.Position
                item.bg.CFrame = targetCF.Rotation
            end
        end
    end)
end

local function grabAt(pos)
    if holding then return end
    local root = getRoot()
    if not root then return end
    local target = getTargetFromScreen(pos)
    if not (target and target:IsA("BasePart") and not target.Anchored) then return end

    local parts = collectParts(target)
    mainPart = pickMain(parts)

    local dir = root.Position - mainPart.Position
    if dir.Magnitude > 0.1 then
        lockedRotation = CFrame.lookAt(Vector3.zero, dir.Unit).Rotation
    else
        lockedRotation = mainPart.CFrame.Rotation
    end

    local mainCF = mainPart.CFrame
    grabbedList = {}
    for _, p in ipairs(parts) do
        local offset = mainCF:ToObjectSpace(p.CFrame)

        local bp = Instance.new("BodyPosition")
        bp.MaxForce = Vector3.new(1e7, 1e7, 1e7)
        bp.P = 5000
        bp.D = 50
        bp.Position = p.Position
        bp.Parent = p

        local bg = Instance.new("BodyGyro")
        bg.MaxTorque = Vector3.new(1e7, 1e7, 1e7)
        bg.P = 5000
        bg.D = 500
        bg.CFrame = p.CFrame
        bg.Parent = p

        p.Massless = true
        p.CanCollide = false
        table.insert(grabbedList, {part = p, offset = offset, bp = bp, bg = bg})
    end
    holding = true
    startFollow()
end

local function throwAtCrosshair()
    if not holding then return end
    holding = false
    if followConn then followConn:Disconnect(); followConn = nil end

    local ray = crosshairRay()
    local velocity = ray.Direction.Unit * THROW_POWER
    for _, item in ipairs(grabbedList) do
        local p = item.part
        if p.Parent then
            item.bp:Destroy()
            item.bg:Destroy()
            p.Massless = false
            p.CanCollide = true
            local bv = Instance.new("BodyVelocity")
            bv.MaxForce = Vector3.new(1e7, 1e7, 1e7)
            bv.Velocity = velocity
            bv.Parent = p
            Debris:AddItem(bv, 5)
        end
    end
    grabbedList = {}
    mainPart = nil
    lockedRotation = nil
end

local function releaseSilently()
    holding = false
    if followConn then followConn:Disconnect(); followConn = nil end
    for _, item in ipairs(grabbedList) do
        local p = item.part
        if p.Parent then
            item.bp:Destroy()
            item.bg:Destroy()
            p.Massless = false
            p.CanCollide = true
        end
    end
    grabbedList = {}
    mainPart = nil
    lockedRotation = nil
end

local function hitToggle(pos)
    return pointInGui(pos, toggleBtn, 6)
end

local function toggleFeature()
    featureEnabled = not featureEnabled
    if not featureEnabled then
        releaseSilently()
    end
    updateToggleVisual()
end

updateToggleVisual()

-- ===== 按钮拖动/点击 =====
local btnDragging = false
local btnMoved = false
local btnDragStart, btnStartPos

-- 关键修改：按钮判断放在 processed 检查之前
UserInputService.InputBegan:Connect(function(input, processed)
    if input.UserInputType ~= Enum.UserInputType.Touch
       and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

    -- 按钮区域：无视 gameProcessed，先接管拖动
    if hitToggle(input.Position) then
        btnDragging = true
        btnMoved = false
        btnDragStart = input.Position
        btnStartPos = toggleBtn.Position
        return
    end

    if processed then return end
    if not featureEnabled then return end

    touchTracker[input] = {
        startPos = input.Position,
        startTime = tick(),
        moved = false,
    }
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Touch
       and input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    if btnDragging then
        local delta = input.Position - btnDragStart
        if delta.Magnitude > 10 then btnMoved = true end
        toggleBtn.Position = UDim2.new(
            btnStartPos.X.Scale, btnStartPos.X.Offset + delta.X,
            btnStartPos.Y.Scale, btnStartPos.Y.Offset + delta.Y
        )
        return
    end

    local state = touchTracker[input]
    if not state then return end
    if (input.Position - state.startPos).Magnitude > MOVE_THRESHOLD then
        state.moved = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Touch
       and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

    if btnDragging then
        btnDragging = false
        if not btnMoved then
            toggleFeature()
        end
        return
    end

    local state = touchTracker[input]
    if not state then return end
    touchTracker[input] = nil

    if not featureEnabled then return end
    if state.moved then return end
    if tick() - state.startTime > TIME_THRESHOLD then return end

    if holding then
        throwAtCrosshair()
    else
        grabAt(input.Position)
    end
end)

-- ===== PC 端 F 键 =====
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F then
        toggleFeature()
    end
end)
