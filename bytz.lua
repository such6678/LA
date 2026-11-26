-- 重复下发保护：先停掉上一次的驱动与面板，避免双循环抢方向盘
if getgenv().RouteAutoRun and type(getgenv().RouteAutoRun) == "table" and getgenv().RouteAutoRun.stop then
    pcall(getgenv().RouteAutoRun.stop)
end
if getgenv().__RouteDriveCleanup then
    pcall(getgenv().__RouteDriveCleanup)
end
getgenv().__RouteDriveCleanup = nil

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
local ClientFolder = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local CarController = require(ClientFolder:WaitForChild("CarController"))
local RoadPath = require(ReplicatedStorage.Shared.Rules.RoadPath)
local WorldConfig = require(ReplicatedStorage.Shared.Config.World)

local listenerConfig = nil
local listenerModule = ReplicatedStorage.Shared.Config:FindFirstChild("Listener")
if listenerModule then
    local listenerSuccess, listenerValue = pcall(require, listenerModule)
    if listenerSuccess and type(listenerValue) == "table" then
        listenerConfig = listenerValue
    end
end

local quietSpeed = 46
if listenerConfig and type(listenerConfig.Quiet) == "number" then
    quietSpeed = listenerConfig.Quiet - 2
end
local maximumSpeed = 200
local minimumSpeed = 200
local alertSpeed = quietSpeed
local acceleration = 150
local maximumYawRate = 3.2
local lookAhead = 12
local yawGain = 4.0
local snapDistance = 70
local stallTime = 0.9
local mapWatchInterval = 2
local glowGuardInterval = 0.5

-- ===== 提前转向避障（全程不减速）=====
local avoidEnabled = true
local avoidRoom = 16            -- 横向让开幅度(studs)
local avoidScanInterval = 0.07  -- 障碍扫描节流(秒)
local avoidLead = 1.95          -- 探测提前倍数（乘速度，越大越早发现）
local avoidMinReach = 150       -- 最低探测距离(studs)
local avoidMaxReach = 360       -- 最高探测距离(studs)
local avoidHorizon = 36         -- 近距紧急判定距离(studs)
local avoidCpaHorizon = 3.6     -- 相对速度预测时间窗(秒)

local pathData = nil
local pathSamples = nil
local pathSampleCount = 0
local pathSampleSpacing = 4
local currentSampleIndex = 1
local currentSpeed = 0
local progressPercent = 0
local stallTimer = 0
local stallStage = 0
local offPathTimer = 0
local glowGuardTimer = 0
local promptGuis = {}
local promptRefreshTimer = 0
local holdKeyPressed = false
local holdClickPressed = false
local heldKeyCode = nil
local forcedKeyCode = nil
-- 避障状态
local avoidOffset = 0
local obsDist, obsSide, obsHW, obsIsCar, obsName = math.huge, 0, 5, false, "none"
local obsScanTimer = 0

if not getgenv().__routeNamecallHooked then
    getgenv().__routeNamecallHooked = true
    local rawMetatable = getrawmetatable(game)
    local originalNamecall = rawMetatable.__namecall
    setreadonly(rawMetatable, false)
    rawMetatable.__namecall = newcclosure(function(self, ...)
        if forcedKeyCode ~= nil and getnamecallmethod() == "IsKeyDown" then
            local firstArgument = ...
            if firstArgument == forcedKeyCode then
                return true
            end
        end
        return originalNamecall(self, ...)
    end)
    setreadonly(rawMetatable, true)
end
local isRunning = false
local destroyed = false
local activeMapSignature = ""
local listenerGui = nil
local listenerLabels = {}
local listenerRefreshTimer = 0
local alertHoldTimer = 0
local caughtScreen = nil
local finishScreen = nil

local function wrapAngle(angle)
    while angle > math.pi do angle = angle - 2 * math.pi end
    while angle < -math.pi do angle = angle + 2 * math.pi end
    return angle
end

local function sampleHeading(sample)
    return math.atan2(sample.fx or 0, -(sample.fz or -1))
end

local function buildRoadPath()
    local success, built = pcall(function()
        return RoadPath.build(WorldConfig)
    end)
    if not success or type(built) ~= "table" or type(built.samples) ~= "table" then
        pathData = nil
        pathSamples = nil
        pathSampleCount = 0
        return false
    end
    if #built.samples <= 50 or (built.length or 0) <= 500 then
        pathData = nil
        pathSamples = nil
        pathSampleCount = 0
        return false
    end
    pathData = built
    pathSamples = built.samples
    pathSampleCount = #pathSamples
    local spacing = pathSampleCount > 1 and (pathSamples[2].s - pathSamples[1].s) or 4
    if spacing <= 0 then spacing = 4 end
    pathSampleSpacing = spacing
    currentSampleIndex = 1
    stallTimer = 0
    offPathTimer = 0
    return true
end

local function computeMapSignature()
    local pieces = { tostring(game.PlaceId) }
    local mapFolder = Workspace:FindFirstChild("Map")
    if mapFolder then
        for _, child in ipairs(mapFolder:GetChildren()) do
            pieces[#pieces + 1] = child.Name
        end
    end
    local roadFloor = Workspace:FindFirstChild("RoadFloor")
    if roadFloor then
        local parts = roadFloor:GetChildren()
        pieces[#pieces + 1] = tostring(#parts)
        local firstPart = parts[1]
        if firstPart and firstPart:IsA("BasePart") then
            pieces[#pieces + 1] = string.format("%.0f,%.0f", firstPart.Position.X, firstPart.Position.Z)
        end
    end
    return table.concat(pieces, "|")
end

local function findNearestSampleIndex(position)
    local bestIndex = currentSampleIndex
    local bestDistance = math.huge
    local lowestIndex = math.max(1, currentSampleIndex - 80)
    local highestIndex = math.min(pathSampleCount, currentSampleIndex + 80)
    for index = lowestIndex, highestIndex do
        local sample = pathSamples[index]
        local offsetX = sample.x - position.X
        local offsetZ = sample.z - position.Z
        local distance = offsetX * offsetX + offsetZ * offsetZ
        if distance < bestDistance then
            bestDistance = distance
            bestIndex = index
        end
    end
    if bestDistance > 6400 then
        for index = 1, pathSampleCount do
            local sample = pathSamples[index]
            local offsetX = sample.x - position.X
            local offsetZ = sample.z - position.Z
            local distance = offsetX * offsetX + offsetZ * offsetZ
            if distance < bestDistance then
                bestDistance = distance
                bestIndex = index
            end
        end
    end
    currentSampleIndex = bestIndex
    return bestIndex, math.sqrt(bestDistance)
end

local function refreshListenerLabels()
    listenerRefreshTimer = 0.4
    listenerLabels = {}
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not listenerGui or not listenerGui.Parent then
        listenerGui = playerGui and playerGui:FindFirstChild("Listener")
    end
    if listenerGui then
        for _, descendant in ipairs(listenerGui:GetDescendants()) do
            if descendant:IsA("TextLabel") then
                listenerLabels[#listenerLabels + 1] = descendant
            end
        end
    end
end

local function listenerIsAlerting(deltaTime)
    listenerRefreshTimer = listenerRefreshTimer - deltaTime
    if listenerRefreshTimer <= 0 then
        refreshListenerLabels()
    end
    if not listenerGui or not listenerGui.Enabled then
        alertHoldTimer = 0
        return false
    end
    local alerting = false
    for index = 1, #listenerLabels do
        local label = listenerLabels[index]
        if label.Parent and label.Visible then
            local text = label.Text or ""
            if string.find(text, "HEAR") ~= nil or string.find(text, "LISTEN") ~= nil then
                alerting = true
                break
            end
        end
    end
    if alerting then
        alertHoldTimer = 1.2
    elseif alertHoldTimer > 0 then
        alertHoldTimer = alertHoldTimer - deltaTime
        alerting = alertHoldTimer > 0
    end
    return alerting
end

local function runHasEnded()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return false end
    if not caughtScreen or not caughtScreen.Parent then
        caughtScreen = playerGui:FindFirstChild("Caught")
    end
    if not finishScreen or not finishScreen.Parent then
        finishScreen = playerGui:FindFirstChild("Finish")
    end
    if caughtScreen then
        if caughtScreen:IsA("ScreenGui") then
            if caughtScreen.Enabled then return true end
        elseif caughtScreen.Visible then
            return true
        end
    end
    if finishScreen then
        if finishScreen:IsA("ScreenGui") then
            return finishScreen.Enabled
        end
        return finishScreen.Visible == true
    end
    return false
end

local function guardScreenGlow(deltaTime)
    glowGuardTimer = glowGuardTimer - deltaTime
    if glowGuardTimer > 0 then return end
    glowGuardTimer = glowGuardInterval
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("ColorCorrectionEffect") and effect.Brightness > 0.15 then
            effect.Brightness = 0.15
            effect.Contrast = 0
            effect.Saturation = 0
            effect.TintColor = Color3.fromRGB(255, 255, 255)
        end
    end
end

local function refreshPromptGuis()
    promptRefreshTimer = 0.5
    promptGuis = {}
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end
    for _, name in ipairs({ "WindowCrank", "CrawlerDoor", "Flashlight", "MusicBoxPrompt" }) do
        local gui = playerGui:FindFirstChild(name)
        if gui then
            promptGuis[#promptGuis + 1] = gui
        end
    end
end

local function setHeldKey(keyCode)
    if heldKeyCode == keyCode then
        forcedKeyCode = keyCode
        return
    end
    if heldKeyCode then
        local previousKey = heldKeyCode
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, previousKey, false, game)
        end)
    end
    heldKeyCode = keyCode
    forcedKeyCode = keyCode
    if keyCode then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        end)
    end
end

local function setHeldClick(pressed)
    if holdClickPressed == pressed then return end
    holdClickPressed = pressed
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, pressed, game, 0)
    end)
end

local function findPromptKey(gui)
    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            local text = descendant.Text or ""
            if descendant.Name == "Letter" then
                local singleLetter = string.match(text, "^%s*([A-Z])%s*$")
                if singleLetter and Enum.KeyCode[singleLetter] then
                    return Enum.KeyCode[singleLetter]
                end
            end
            local letter = string.match(text, "HOLD%s*([A-Z])")
            if letter and Enum.KeyCode[letter] then
                return Enum.KeyCode[letter]
            end
        end
    end
    return Enum.KeyCode.G
end

local function updateHoldPrompts(deltaTime)
    promptRefreshTimer = promptRefreshTimer - deltaTime
    if promptRefreshTimer <= 0 then
        refreshPromptGuis()
    end
    local pressedKey = nil
    local needClick = false
    for index = 1, #promptGuis do
        local gui = promptGuis[index]
        local visible = false
        if gui:IsA("ScreenGui") then
            visible = gui.Enabled
        else
            local ok, value = pcall(function() return gui.Visible end)
            visible = ok and value == true
        end
        if visible then
            if gui.Name == "MusicBoxPrompt" then
                needClick = true
            else
                local promptKey = findPromptKey(gui)
                if promptKey then
                    pressedKey = promptKey
                elseif not pressedKey then
                    pressedKey = Enum.KeyCode.G
                end
            end
        end
    end
    setHeldKey(pressedKey)
    setHeldClick(needClick)
end

local function flatVec(v)
    return Vector3.new(v.X, 0, v.Z)
end

-- 障碍扫描：相对速度 + 最近接点(CPA) 判危险
-- 静态物(树/石头/护栏)用射线补盲；其他车/怪物用相对速度预测
local function scanObstacle(pos, fwd, right, myCar, reach, myVel)
    local bestScore, bestD, bestS, bestN, bestHW = math.huge, math.huge, 0, nil, 5
    local bestIsCar = false
    local myV = flatVec(myVel or Vector3.zero)
    local myHalf = 5

    local function test(p, name, hw, vel, isCar)
        local rel = flatVec(p - pos)
        local fNow = rel:Dot(fwd)
        local sdNow = rel:Dot(right)
        if fNow > reach or fNow < -10 then return end
        local hwv = hw or 6
        local latWide = hwv + myHalf + 9
        local onPathNow = math.abs(sdNow) < latWide + math.max(fNow, 0) * 0.035

        local v = flatVec(vel or Vector3.zero)
        local relV = v - myV
        local tCPA, cpaF, cpaLat = math.huge, fNow, sdNow
        local vv = relV:Dot(relV)
        if vv > 4 then
            local t = -(rel:Dot(relV)) / vv
            if t < 0 then t = 0 elseif t > avoidCpaHorizon then t = avoidCpaHorizon end
            tCPA = t
            local cp = rel + relV * t
            cpaF = cp:Dot(fwd)
            cpaLat = cp:Dot(right)
        end

        local danger = false
        if fNow > 2 and fNow < avoidHorizon and onPathNow then
            danger = true
        elseif tCPA < avoidCpaHorizon * 0.85 and math.abs(cpaLat) < latWide and cpaF > 2 then
            danger = true
        end
        if not danger then return end

        local score = fNow
        if isCar then score = score * 0.55 end
        if score < bestScore then
            bestScore = score
            bestD, bestS, bestN, bestHW = fNow, sdNow, name, hwv
            bestIsCar = isCar and true or false
        end
    end

    local cars = Workspace:FindFirstChild("Cars")
    if cars then
        for _, c in ipairs(cars:GetChildren()) do
            local owner = c:GetAttribute("Owner")
            local isSelf = (c == myCar) or (owner ~= nil and owner == LocalPlayer.UserId)
            if not isSelf then
                local ch = c:FindFirstChild("Chassis")
                if ch and ch:IsA("BasePart") then
                    local hw = math.max(ch.Size.X, ch.Size.Z) * 0.5
                    test(ch.Position, c.Name, hw, ch.AssemblyLinearVelocity, true)
                end
            end
        end
    end
    local mon = Workspace:FindFirstChild("ClientMonsters")
    if mon then
        for _, m in ipairs(mon:GetChildren()) do
            local hrp = m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Chassis")
            if not hrp and m:IsA("BasePart") then hrp = m end
            if hrp and hrp:IsA("BasePart") then
                local hw = math.max(hrp.Size.X, hrp.Size.Z) * 0.5
                test(hrp.Position, m.Name, hw, hrp.AssemblyLinearVelocity, true)
            end
        end
    end

    -- 射线补盲：抓静态路障
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local filter = { myCar, LocalPlayer.Character }
    if cars then filter[#filter + 1] = cars end
    rp.FilterDescendantsInstances = filter
    rp.IgnoreWater = true
    local rayLen = math.min(reach, 320)
    for _, o in ipairs({ -13, -8, -4, 0, 4, 8, 13 }) do
        local org = pos + Vector3.new(0, 2.2, 0) + right * o
        local hit = Workspace:Raycast(org, fwd * rayLen, rp)
        local hitName = (hit and hit.Instance) and hit.Instance.Name or ""
        local ignorable = (hitName == "Portal" or hitName == "Checkpoint"
            or hitName == "Spawn" or hitName == "FinishLine")
        if hit and hit.Instance ~= Workspace.Terrain and hit.Normal.Y < 0.62 and not ignorable then
            local f = (hit.Position - pos):Dot(fwd)
            local hw = 6
            if hit.Instance:IsA("BasePart") then
                hw = math.min(hit.Instance.Size.X, hit.Instance.Size.Z) * 0.5
            end
            if f > 3 then
                local sc = f
                if sc < bestScore then
                    bestScore = sc
                    bestD, bestS, bestN, bestHW = f, o, hit.Instance.Name, hw
                    bestIsCar = false
                end
            end
        end
    end
    obsDist, obsSide, obsName, obsHW, obsIsCar = bestD, bestS, bestN or "none", bestHW, bestIsCar
end

local function driveFrame(deltaTime)
    local car = CarController.state.car
    if not car then return end
    local chassis = car:FindFirstChild("Chassis") or car.PrimaryPart
    if not chassis then return end

    guardScreenGlow(deltaTime)
    updateHoldPrompts(deltaTime)

    if not pathSamples then return end

    if runHasEnded() then
        chassis.AssemblyLinearVelocity = Vector3.new(0, chassis.AssemblyLinearVelocity.Y, 0)
        chassis.AssemblyAngularVelocity = Vector3.zero
        return
    end

    local position = chassis.Position
    local velocity = chassis.AssemblyLinearVelocity
    local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

    local nearestIndex, lateralDistance = findNearestSampleIndex(position)
    progressPercent = (pathSamples[nearestIndex].s or 0) / pathData.length * 100

    if nearestIndex >= pathSampleCount - 2 then
        local lastSample = pathSamples[pathSampleCount]
        local finalDirection = Vector3.new(lastSample.fx or 0, 0, lastSample.fz or -1)
        finalDirection = finalDirection.Unit
        chassis.AssemblyLinearVelocity = Vector3.new(finalDirection.X * 110, velocity.Y, finalDirection.Z * 110)
        chassis.AssemblyAngularVelocity = Vector3.zero
        return
    end

    if lateralDistance > snapDistance then
        if lateralDistance > 200 then
            offPathTimer = offPathTimer + deltaTime
            if offPathTimer > 4 then
                offPathTimer = 0
                buildRoadPath()
            end
            return
        end
        local nearestSample = pathSamples[nearestIndex]
        chassis.CFrame = CFrame.new(nearestSample.x, nearestSample.y + 3, nearestSample.z)
        return
    end
    offPathTimer = 0

    local aheadIndex = math.min(pathSampleCount, nearestIndex + lookAhead)
    local headingDelta = math.abs(wrapAngle(sampleHeading(pathSamples[aheadIndex]) - sampleHeading(pathSamples[nearestIndex])))
    local arcLength = math.max(pathSampleSpacing * (aheadIndex - nearestIndex), 1)
    local curvature = headingDelta / arcLength

    local speedLimit = maximumSpeed
    if curvature > 0.0001 then
        speedLimit = math.clamp(maximumYawRate / curvature, minimumSpeed, maximumSpeed)
    end
    if listenerIsAlerting(deltaTime) then
        speedLimit = math.min(speedLimit, alertSpeed)
    end

    local speedDelta = math.clamp(speedLimit - horizontalSpeed, -acceleration * deltaTime * 2.5, acceleration * deltaTime)
    currentSpeed = math.max(0, horizontalSpeed + speedDelta)

    local targetSample = pathSamples[aheadIndex]
    local direction = Vector3.new(targetSample.x - position.X, 0, targetSample.z - position.Z)
    if direction.Magnitude < 0.001 then
        direction = Vector3.new(targetSample.fx or 0, 0, targetSample.fz or -1)
    end
    direction = direction.Unit

    local lookVector = chassis.CFrame.LookVector
    local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
    if flatLook.Magnitude > 0.001 then flatLook = flatLook.Unit else flatLook = direction end
    local fwd = flatLook
    local right = Vector3.new(-fwd.Z, 0, fwd.X)

    -- 障碍扫描（节流）：探测距离随速度提高（提前量可调）
    obsScanTimer = obsScanTimer + deltaTime
    local avoidReach = math.clamp(horizontalSpeed * avoidLead, avoidMinReach, avoidMaxReach)
    if obsScanTimer >= avoidScanInterval then
        obsScanTimer = 0
        scanObstacle(position, fwd, right, car, avoidReach, velocity)
    end

    -- 提前转向避让：远处先微偏，近了打满；全程不减速
    local avoidBand = avoidReach
    local wantAvoid = 0
    if avoidEnabled and obsDist < avoidBand then
        local k = math.clamp(1 - obsDist / avoidBand, 0, 1)
        local sgn = (obsSide > 1.5) and -1 or 1   -- 障碍在右往左让；正对默认往右
        local halfObs = obsHW or 5
        local amp = math.min(avoidRoom + halfObs * 0.7, 30)
        wantAvoid = sgn * amp * (k ^ 0.78)
    end
    avoidOffset = avoidOffset + (wantAvoid - avoidOffset) * math.min(1, deltaTime * 8.0)

    -- 把横向偏移加到前方目标点，方向自然提前掰过去
    if math.abs(avoidOffset) > 0.05 then
        local tp = Vector3.new(
            targetSample.x + right.X * avoidOffset,
            0,
            targetSample.z + right.Z * avoidOffset)
        local nd = flatVec(tp - position)
        if nd.Magnitude > 0.001 then direction = nd.Unit end
    end

    chassis.AssemblyLinearVelocity = Vector3.new(direction.X * currentSpeed, velocity.Y, direction.Z * currentSpeed)

    if flatLook.Magnitude > 0.001 then
        local yawError = math.atan2(flatLook:Cross(direction).Y, flatLook:Dot(direction))
        chassis.AssemblyAngularVelocity = Vector3.new(0, yawError * yawGain, 0)
    end

    if horizontalSpeed < 3 then
        stallTimer = stallTimer + deltaTime
        if stallTimer > stallTime then
            stallTimer = 0
            stallStage = math.min(stallStage + 1, 5)
            local skipSamples = 4 + stallStage * 9
            local liftHeight = 4 + stallStage * 3
            local skipIndex = math.min(pathSampleCount, nearestIndex + skipSamples)
            local skipSample = pathSamples[skipIndex]
            chassis.CanCollide = false
            chassis.CFrame = CFrame.new(skipSample.x, skipSample.y + liftHeight, skipSample.z)
            local skipDirection = Vector3.new(skipSample.fx or 0, 0, skipSample.fz or -1)
            chassis.AssemblyLinearVelocity = Vector3.new(skipDirection.X * 110, 0, skipDirection.Z * 110)
            chassis.AssemblyAngularVelocity = Vector3.zero
            task.delay(0.5 + stallStage * 0.25, function()
                if chassis and chassis.Parent then
                    chassis.CanCollide = true
                end
            end)
        end
    else
        stallTimer = 0
        if horizontalSpeed > 25 then
            stallStage = 0
        end
    end
end

local function startDriving()
    isRunning = true
    stallTimer = 0
end

local function stopDriving()
    isRunning = false
    setHeldKey(false)
    setHeldClick(false)
    local car = CarController.state.car
    local chassis = car and car:FindFirstChild("Chassis")
    if chassis then
        chassis.AssemblyLinearVelocity = Vector3.new(0, chassis.AssemblyLinearVelocity.Y, 0)
        chassis.AssemblyAngularVelocity = Vector3.zero
    end
end

local heartbeatConn = RunService.Heartbeat:Connect(function(deltaTime)
    if destroyed or not isRunning then return end
    local success, message = pcall(driveFrame, deltaTime)
    if not success then
        warn(tostring(message))
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F2 then
        if isRunning then
            stopDriving()
        else
            startDriving()
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    currentSampleIndex = 1
    stallTimer = 0
    offPathTimer = 0
end)

task.spawn(function()
    local pendingSignature = nil
    while not destroyed do
        task.wait(mapWatchInterval)
        local signature = computeMapSignature()
        if signature == activeMapSignature then
            pendingSignature = nil
        elseif pendingSignature == signature then
            pendingSignature = nil
            activeMapSignature = signature
            buildRoadPath()
        else
            pendingSignature = signature
        end
    end
end)

activeMapSignature = computeMapSignature()
buildRoadPath()
refreshListenerLabels()

getgenv().RouteAvoid = function(v)
    if v ~= nil then avoidEnabled = (v ~= false) end
    return avoidEnabled
end

getgenv().RouteConfig = {
    getSpeed = function() return maximumSpeed end,
    setSpeed = function(v)
        v = math.clamp(tonumber(v) or 200, 120, 300)
        maximumSpeed = v
        minimumSpeed = v
        getgenv().__RouteTune = (getgenv().__RouteTune or 0) + 1
        return v
    end,
    getAvoid = function() return avoidEnabled end,
    setAvoid = function(v)
        avoidEnabled = (v ~= false)
        getgenv().__RouteTune = (getgenv().__RouteTune or 0) + 1
        return avoidEnabled
    end,
    getLead = function() return avoidLead end,
    setLead = function(v)
        avoidLead = math.clamp(tonumber(v) or 1.95, 1.0, 3.2)
        getgenv().__RouteTune = (getgenv().__RouteTune or 0) + 1
        return avoidLead
    end,
    getRoom = function() return avoidRoom end,
    setRoom = function(v)
        avoidRoom = math.clamp(tonumber(v) or 16, 6, 32)
        getgenv().__RouteTune = (getgenv().__RouteTune or 0) + 1
        return avoidRoom
    end,
}

getgenv().RouteStats = function()
    local car = CarController.state.car
    local chassis = car and car:FindFirstChild("Chassis")
    local speed = 0
    if chassis then
        local velocity = chassis.AssemblyLinearVelocity
        speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
    end
    return {
        running = isRunning,
        speed = speed,
        target = currentSpeed,
        progress = progressPercent,
        samples = pathSampleCount,
        avoid = avoidEnabled,
        lead = avoidLead,
        room = avoidRoom,
        obj = obsName,
        dist = (obsDist == math.huge) and -1 or obsDist,
        off = avoidOffset,
    }
end

getgenv().RouteAutoRun = {
    start = startDriving,
    stop = stopDriving,
    status = function()
        local car = CarController.state.car
        local chassis = car and car:FindFirstChild("Chassis")
        local speed = 0
        if chassis then
            local velocity = chassis.AssemblyLinearVelocity
            speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
        end
        return string.format("running=%s speed=%.0f target=%.0f progress=%.1f%% samples=%d avoid=%s obj=%s@%.0f off=%.1f",
            tostring(isRunning), speed, currentSpeed, progressPercent, pathSampleCount,
            tostring(avoidEnabled), obsName, obsDist == math.huge and -1 or obsDist, avoidOffset)
    end
}

-- ==================== 控制面板 ====================
do
    local pg = LocalPlayer:WaitForChild("PlayerGui")
    local oldGui = pg:FindFirstChild("RouteDriveUI")
    if oldGui then oldGui:Destroy() end

    local ACCENT = Color3.fromRGB(255, 138, 76)
    local TEAL   = Color3.fromRGB(110, 210, 190)
    local GREEN  = Color3.fromRGB(96, 208, 138)
    local RED    = Color3.fromRGB(216, 98, 84)
    local INK    = Color3.fromRGB(16, 18, 24)
    local PANEL  = Color3.fromRGB(27, 30, 40)
    local CARD   = Color3.fromRGB(34, 38, 50)
    local BORDER = Color3.fromRGB(56, 62, 78)
    local WHITE  = Color3.fromRGB(238, 241, 248)
    local MUTED  = Color3.fromRGB(140, 147, 168)
    local DIM    = Color3.fromRGB(92, 98, 116)

    local function mk(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    local function rnd(o, r)
        mk("UICorner", { CornerRadius = UDim.new(0, r) }, o)
        return o
    end
    local function stro(o, c, t)
        mk("UIStroke", { Color = c or BORDER, Thickness = t or 1 }, o)
        return o
    end
    local function label(parent, txt, x, y, w, h, size, color, bold, align)
        return mk("TextLabel", {
            Size = UDim2.fromOffset(w, h), Position = UDim2.fromOffset(x, y),
            BackgroundTransparency = 1, Text = txt, TextSize = size or 12,
            TextColor3 = color or WHITE,
            Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
            TextXAlignment = align or Enum.TextXAlignment.Left,
        }, parent)
    end

    local W, H = 360, 544
    local interactives = {}
    local locked = true
    local gui = mk("ScreenGui", {
        Name = "RouteDriveUI", ResetOnSpawn = false, IgnoreGuiInset = true,
        DisplayOrder = 128, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, pg)

    local main = mk("Frame", {
        Name = "Main", Size = UDim2.fromOffset(W, H),
        AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(0, 16, 0, 86),
        BackgroundColor3 = INK, BorderSizePixel = 0,
    }, gui)
    rnd(main, 14)
    stro(main, BORDER, 1)

    local uiScale = mk("UIScale", { Scale = 1 }, main)
    local function fitScale()
        local cam = workspace.CurrentCamera
        local vh = cam and cam.ViewportSize.Y or 800
        uiScale.Scale = math.clamp((vh - 190) / H, 0.55, 1)
    end
    fitScale()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)
    end
    local readyAt = tick() + 0.6

    -- 标题栏
    local bar = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = PANEL, BorderSizePixel = 0,
    }, main)
    rnd(bar, 14)
    mk("Frame", {
        Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 1, -16),
        BackgroundColor3 = PANEL, BorderSizePixel = 0,
    }, bar)
    local acc = mk("Frame", {
        Size = UDim2.fromOffset(3, 15), Position = UDim2.fromOffset(14, 15),
        BackgroundColor3 = ACCENT, BorderSizePixel = 0,
    }, bar)
    rnd(acc, 2)
    label(bar, "不要停止 · 自动驾驶", 26, 0, 220, 44, 14, WHITE, true)

    local lockBtn = mk("TextButton", {
        Size = UDim2.fromOffset(26, 24), Position = UDim2.new(1, -96, 0, 10),
        BackgroundColor3 = Color3.fromRGB(70, 76, 94), Text = "锁", TextSize = 11,
        TextColor3 = WHITE, Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false,
    }, bar)
    rnd(lockBtn, 7)
    local minBtn = mk("TextButton", {
        Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -64, 0, 10),
        BackgroundColor3 = Color3.fromRGB(48, 53, 68), Text = "—", TextSize = 12,
        TextColor3 = MUTED, Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false,
    }, bar)
    rnd(minBtn, 7)
    local closeBtn = mk("TextButton", {
        Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -34, 0, 10),
        BackgroundColor3 = Color3.fromRGB(48, 53, 68), Text = "x", TextSize = 12,
        TextColor3 = MUTED, Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false,
    }, bar)
    rnd(closeBtn, 7)

    -- 拖动
    do
        local drag, startPos, startInput = false, nil, nil
        bar.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                drag = true
                startInput = i.Position
                startPos = main.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - startInput
                main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                if drag then
                    drag = false
                    local cam = workspace.CurrentCamera
                    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
                    local sz = main.AbsoluteSize
                    local ap = main.AbsolutePosition
                    local nx = math.clamp(ap.X, 0, math.max(0, vp.X - sz.X))
                    local ny = math.clamp(ap.Y, 0, math.max(0, vp.Y - sz.Y))
                    if math.abs(nx - ap.X) > 1 or math.abs(ny - ap.Y) > 1 then
                        main.Position = UDim2.fromOffset(nx, ny)
                    end
                end
            end
        end)
    end

    -- 状态条
    local statusBar = mk("Frame", {
        Size = UDim2.fromOffset(W - 28, 46), Position = UDim2.fromOffset(14, 54),
        BackgroundColor3 = CARD, BorderSizePixel = 0,
    }, main)
    rnd(statusBar, 10)
    stro(statusBar, BORDER, 1)
    local dot = mk("Frame", {
        Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(14, 19),
        BackgroundColor3 = GREEN, BorderSizePixel = 0,
    }, statusBar)
    rnd(dot, 4)
    local stateLbl = label(statusBar, "运行中", 28, 7, 130, 16, 12, WHITE, true)
    local subLbl = label(statusBar, "速度 0", 28, 24, 170, 13, 9, MUTED)
    local speedBig = label(statusBar, "0", 190, 4, 78, 26, 21, ACCENT, true, Enum.TextXAlignment.Right)
    label(statusBar, "studs/s", 274, 28, 44, 12, 8, DIM, false, Enum.TextXAlignment.Right)

    -- 主按钮
    local runBtn = mk("TextButton", {
        Size = UDim2.fromOffset(W - 28, 36), Position = UDim2.fromOffset(14, 108),
        BackgroundColor3 = RED, Text = "停 止", TextColor3 = Color3.fromRGB(255, 242, 238),
        TextSize = 13, Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false,
    }, main)
    rnd(runBtn, 9)

    -- 拖动条
    local function slider(y, title, minv, maxv, stepv, getter, setter, fmt)
        label(main, title, 16, y, 170, 18, 12, WHITE, true)
        local val = label(main, "", W - 106, y, 74, 18, 12, ACCENT, true, Enum.TextXAlignment.Right)
        local track = mk("Frame", {
            Size = UDim2.fromOffset(W - 28, 6), Position = UDim2.fromOffset(14, y + 30),
            BackgroundColor3 = Color3.fromRGB(45, 50, 64), BorderSizePixel = 0,
        }, main)
        rnd(track, 3)
        local fill = mk("Frame", {
            Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = ACCENT, BorderSizePixel = 0, ZIndex = 2,
        }, track)
        rnd(fill, 3)
        local knob = mk("Frame", {
            Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0), BackgroundColor3 = WHITE,
            BorderSizePixel = 0, ZIndex = 3,
        }, track)
        rnd(knob, 8)
        stro(knob, ACCENT, 2)
        local hit = mk("TextButton", {
            Size = UDim2.new(1, 16, 0, 32), Position = UDim2.fromOffset(-8, -13),
            BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 5,
        }, track)

        local dragging = false
        local function refresh()
            local v = math.clamp(getter(), minv, maxv)
            local ratio = (maxv > minv) and (v - minv) / (maxv - minv) or 0
            fill.Size = UDim2.new(ratio, 0, 1, 0)
            knob.Position = UDim2.new(ratio, 0, 0.5, 0)
            val.Text = fmt and fmt(v) or tostring(math.floor(v))
        end
        local function fromX(px)
            if locked then return end
            local ap = track.AbsolutePosition.X
            local aw = track.AbsoluteSize.X
            if aw < 40 then return end
            local ratio = math.clamp((px - ap) / aw, 0, 1)
            local v = minv + ratio * (maxv - minv)
            if stepv and stepv > 0 then
                v = minv + math.floor((v - minv) / stepv + 0.5) * stepv
            end
            setter(math.clamp(v, minv, maxv))
            refresh()
        end
        hit.InputBegan:Connect(function(i)
            if tick() < readyAt then return end
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                fromX(i.Position.X)
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                fromX(i.Position.X)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
        refresh()
        table.insert(interactives, hit)
        return refresh
    end

    local cfg = getgenv().RouteConfig
    local refreshSpeed = slider(152, "巡航速度", 120, 300, 5,
        cfg.getSpeed, cfg.setSpeed, function(v) return string.format("%d", v) end)
    local refreshLead = slider(210, "避障提前量", 1.0, 3.2, 0.05,
        cfg.getLead, cfg.setLead, function(v) return string.format("%.2fx", v) end)
    local refreshRoom = slider(268, "让开幅度", 6, 32, 1,
        cfg.getRoom, cfg.setRoom, function(v) return string.format("%d", v) end)

    -- 避障开关
    local avoidRow = mk("Frame", {
        Size = UDim2.fromOffset(W - 28, 44), Position = UDim2.fromOffset(14, 326),
        BackgroundColor3 = CARD, BorderSizePixel = 0,
    }, main)
    rnd(avoidRow, 10)
    stro(avoidRow, BORDER, 1)
    label(avoidRow, "自动避障", 14, 7, 160, 16, 12, WHITE, true)
    label(avoidRow, "前方有障碍时提前转向躲避", 14, 24, 230, 12, 9, MUTED)
    local swTrack = mk("Frame", {
        Size = UDim2.fromOffset(46, 24), Position = UDim2.new(1, -60, 0.5, -12),
        BackgroundColor3 = GREEN, BorderSizePixel = 0,
    }, avoidRow)
    rnd(swTrack, 12)
    local swKnob = mk("Frame", {
        Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -21, 0.5, -9),
        BackgroundColor3 = WHITE, BorderSizePixel = 0,
    }, avoidRow)
    rnd(swKnob, 9)
    local swHit = mk("TextButton", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
    }, avoidRow)

    -- 数据卡
    local function statCard(i, title, color)
        local card = mk("Frame", {
            Size = UDim2.fromOffset(76, 50), Position = UDim2.fromOffset(19 + i * 82, 378),
            BackgroundColor3 = CARD, BorderSizePixel = 0,
        }, main)
        rnd(card, 9)
        stro(card, BORDER, 1)
        local v = label(card, "-", 0, 5, 76, 22, 14, color, true, Enum.TextXAlignment.Center)
        label(card, title, 0, 29, 76, 12, 9, MUTED, false, Enum.TextXAlignment.Center)
        return v
    end
    local statSpeed = statCard(0, "速度", ACCENT)
    local statProg = statCard(1, "进度", TEAL)
    local statObj = statCard(2, "障碍", MUTED)
    local statOff = statCard(3, "偏移", MUTED)

    -- 日志
    local logBox = mk("Frame", {
        Size = UDim2.fromOffset(W - 28, 76), Position = UDim2.fromOffset(14, 436),
        BackgroundColor3 = Color3.fromRGB(12, 14, 19), BorderSizePixel = 0,
    }, main)
    rnd(logBox, 9)
    stro(logBox, Color3.fromRGB(44, 49, 62), 1)
    local logLabel = mk("TextLabel", {
        Size = UDim2.new(1, -18, 1, -12), Position = UDim2.fromOffset(9, 6),
        BackgroundTransparency = 1, Text = "等待事件...", TextColor3 = Color3.fromRGB(146, 153, 172),
        TextSize = 9, Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, RichText = false,
    }, logBox)

    label(main, "右上「锁」解锁后可调参  ·  右Ctrl 显隐", 16, 518, W - 32, 14, 9, DIM)

    -- 日志缓冲
    local logs = {}
    local function pushLog(txt)
        table.insert(logs, 1, tostring(txt))
        while #logs > 5 do table.remove(logs) end
    end
    pushLog("面板已加载")

    -- 交互
    local visible = true
    table.insert(interactives, runBtn)
    table.insert(interactives, swHit)

    local function applyLock()
        for _, b in ipairs(interactives) do
            pcall(function()
                b.Active = not locked
                b.Selectable = not locked
            end)
        end
        lockBtn.Text = locked and "锁" or "开"
        lockBtn.BackgroundColor3 = locked and Color3.fromRGB(70, 76, 94) or ACCENT
        runBtn.TextColor3 = locked and MUTED or Color3.fromRGB(255, 242, 238)
    end
    applyLock()
    lockBtn.MouseButton1Click:Connect(function()
        locked = not locked
        applyLock()
        pushLog(locked and "面板已锁定（防误触）" or "面板已解锁，可调参数")
    end)

    runBtn.MouseButton1Click:Connect(function()
        if locked then return end
        if isRunning then
            stopDriving()
            pushLog("已停止")
        else
            startDriving()
            pushLog("已启动")
        end
    end)
    swHit.MouseButton1Click:Connect(function()
        if locked then return end
        local nv = cfg.setAvoid(not cfg.getAvoid())
        swTrack.BackgroundColor3 = nv and GREEN or Color3.fromRGB(70, 76, 94)
        swKnob.Position = nv and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
        pushLog(nv and "避障 已开启" or "避障 已关闭")
    end)
    closeBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
        visible = false
    end)
    minBtn.MouseButton1Click:Connect(function()
        gui.Enabled = false
        visible = false
    end)
    UserInputService.InputBegan:Connect(function(i, processed)
        if processed then return end
        if i.KeyCode == Enum.KeyCode.RightControl then
            visible = not visible
            gui.Enabled = visible
        end
    end)

    -- 刷新循环
    local lastObj = nil
    task.spawn(function()
        while not destroyed and gui.Parent do
            local st = getgenv().RouteStats and getgenv().RouteStats()
            if st then
                if st.running then
                    dot.BackgroundColor3 = GREEN
                    stateLbl.Text = "运行中"
                    stateLbl.TextColor3 = WHITE
                    runBtn.Text = "停 止"
                    runBtn.BackgroundColor3 = RED
                    runBtn.TextColor3 = locked and MUTED or Color3.fromRGB(255, 242, 238)
                else
                    dot.BackgroundColor3 = DIM
                    stateLbl.Text = "已停止"
                    stateLbl.TextColor3 = MUTED
                    runBtn.Text = "启 动"
                    runBtn.BackgroundColor3 = ACCENT
                    runBtn.TextColor3 = locked and MUTED or Color3.fromRGB(32, 19, 8)
                end
                swTrack.BackgroundColor3 = st.avoid and GREEN or Color3.fromRGB(70, 76, 94)
                swKnob.Position = st.avoid and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
                speedBig.Text = string.format("%d", st.speed)
                subLbl.Text = string.format("目标 %d   进度 %.1f%%", math.floor(st.target), st.progress)
                statSpeed.Text = string.format("%d", st.speed)
                statProg.Text = string.format("%.0f%%", st.progress)
                if st.dist and st.dist > 0 then
                    statObj.Text = tostring(st.obj or "-"):sub(1, 7)
                    statObj.TextColor3 = (st.dist < 60) and RED or TEAL
                    statOff.Text = string.format("%+.1f", st.off)
                else
                    statObj.Text = "无"
                    statObj.TextColor3 = DIM
                    statOff.Text = "0.0"
                end
                logLabel.Text = (#logs > 0) and table.concat(logs, "\n") or "等待事件..."
                if st.dist and st.dist > 0 and st.obj and st.obj ~= "none" then
                    if st.obj ~= lastObj then
                        pushLog(string.format("避让 %s  距离 %.0f", tostring(st.obj), st.dist))
                        lastObj = st.obj
                    end
                else
                    lastObj = nil
                end
            end
            task.wait(0.12)
        end
    end)

    -- 清理钩子
    local oldCleanup = getgenv().__RouteDriveCleanup
    getgenv().__RouteDriveCleanup = function()
        destroyed = true
        if heartbeatConn then pcall(function() heartbeatConn:Disconnect() end) end
        local g = pg:FindFirstChild("RouteDriveUI")
        if g then g:Destroy() end
        getgenv().RouteAutoRun = nil
        getgenv().RouteConfig = nil
        getgenv().RouteStats = nil
        getgenv().__RouteDriveCleanup = nil
        if oldCleanup then pcall(oldCleanup) end
    end
end
-- ================== 面板结束 ==================

startDriving()
