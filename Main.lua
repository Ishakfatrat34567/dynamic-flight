--!strict
-- LocalScript: Two-mode client-side flight system
-- Controls:
--   F = Toggle Hover Mode
--   E = Toggle Hover/Fast (only while flight is enabled)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local FLIGHT_TOGGLE_KEY = Enum.KeyCode.F
local MODE_SWITCH_KEY = Enum.KeyCode.E

local HOVER_SPEED = 16 -- close to default walk speed
local FAST_SPEED = 150
local VERTICAL_SPEED = 16

local VELOCITY_SMOOTHNESS = 12
local ORIENTATION_SMOOTHNESS = 10

local HOVER_BANK_DEG = 18
local HOVER_PITCH_DEG = 14

local FAST_BANK_DEG = 28
local FAST_CLIMB_PITCH_DEG = 10

local enumToAxis: {[Enum.KeyCode]: Vector3} = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	[Enum.KeyCode.Space] = Vector3.new(0, 1, 0),
	[Enum.KeyCode.LeftControl] = Vector3.new(0, -1, 0),
}

local mode = "off" :: "off" | "hover" | "fast"
local keyState: {[Enum.KeyCode]: boolean} = {}

local rootPart: BasePart? = nil
local humanoid: Humanoid? = nil

local rootAttachment: Attachment? = nil
local linearVelocity: LinearVelocity? = nil
local alignOrientation: AlignOrientation? = nil

local flightVelocity = Vector3.zero
local orientationCF = CFrame.new()
local animateScript: LocalScript? = nil
local animateWasDisabled: boolean? = nil
local animationTracks: {[string]: AnimationTrack} = {}
local activeFlightAnimation = "off" :: "off" | "hover" | "fast"

local heartbeatConn: RBXScriptConnection? = nil

local function ensureCharacter()
	local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	local hum = character:WaitForChild("Humanoid") :: Humanoid
	return character, hrp, hum
end

local function getCameraBasis(includePitch: boolean?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)
	end

	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector

	local usePitch = includePitch == true

	local forwardVector = if usePitch then look else Vector3.new(look.X, 0, look.Z)
	if forwardVector.Magnitude < 1e-4 then
		forwardVector = Vector3.new(0, 0, -1)
	else
		forwardVector = forwardVector.Unit
	end

	local rightVector = if usePitch then right else Vector3.new(right.X, 0, right.Z)
	if rightVector.Magnitude < 1e-4 then
		rightVector = Vector3.new(1, 0, 0)
	else
		rightVector = rightVector.Unit
	end

	return forwardVector, rightVector, Vector3.new(0, 1, 0)
end

local function getMoveIntent(includeCameraPitch: boolean?): Vector3
	local forward, right, up = getCameraBasis(includeCameraPitch)
	local intent = Vector3.zero

	for keyCode, axis in pairs(enumToAxis) do
		if keyState[keyCode] then
			intent += right * axis.X
			intent += up * axis.Y
			intent += forward * (-axis.Z)
		end
	end

	if intent.Magnitude > 1 then
		intent = intent.Unit
	end

	return intent
end

local function destroyFlightConstraints()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	if linearVelocity then
		linearVelocity:Destroy()
		linearVelocity = nil
	end

	if alignOrientation then
		alignOrientation:Destroy()
		alignOrientation = nil
	end

	if rootAttachment then
		rootAttachment:Destroy()
		rootAttachment = nil
	end
end

local function stopAllFlightAnimationTracks()
	for _, track in pairs(animationTracks) do
		if track.IsPlaying then
			track:Stop(0.15)
		end
		track:Destroy()
	end
	table.clear(animationTracks)
end

local function getCharacterAnimationByName(character: Model, folderName: string, animationName: string): Animation?
	local animate = character:FindFirstChild("Animate")
	if not animate then
		return nil
	end

	local animFolder = animate:FindFirstChild(folderName)
	if not animFolder then
		return nil
	end

	local anim = animFolder:FindFirstChild(animationName)
	if anim and anim:IsA("Animation") then
		return anim
	end

	return nil
end

local function getHoverIdleAnimation(character: Model): Animation
	local idleAnim1 = getCharacterAnimationByName(character, "idle", "Animation1")
	if idleAnim1 then
		return idleAnim1
	end

	local idleAnim2 = getCharacterAnimationByName(character, "idle", "Animation2")
	if idleAnim2 then
		return idleAnim2
	end

	local fallback = Instance.new("Animation")
	fallback.AnimationId = "rbxassetid://507766388"
	return fallback
end

local function getFastFallAnimation(character: Model): Animation
	local fallAnim = getCharacterAnimationByName(character, "fall", "FallAnim")
	if fallAnim then
		return fallAnim
	end

	local fallback = Instance.new("Animation")
	fallback.AnimationId = "rbxassetid://507767968"
	return fallback
end

local function setFlightAnimation(target: "off" | "hover" | "fast")
	if activeFlightAnimation == target and target ~= "off" then
		return
	end

	local character = localPlayer.Character
	if target == "off" then
		stopAllFlightAnimationTracks()
		if character then
			animateScript = character:FindFirstChild("Animate") :: LocalScript?
		end
		if animateScript and animateWasDisabled ~= nil then
			animateScript.Disabled = animateWasDisabled
		end
		animateWasDisabled = nil
		activeFlightAnimation = "off"
		return
	end

	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end

	animateScript = character:FindFirstChild("Animate") :: LocalScript?

	if animateScript and animateWasDisabled == nil then
		animateWasDisabled = animateScript.Disabled
		animateScript.Disabled = true
	end

	stopAllFlightAnimationTracks()

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = if target == "hover" then getHoverIdleAnimation(character) else getFastFallAnimation(character)
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15, 1, 1)
	animationTracks[target] = track
	activeFlightAnimation = target

	if animation.Parent == nil then
		animation:Destroy()
	end
end

local function stopFlight()
	mode = "off"
	destroyFlightConstraints()

	if humanoid then
		humanoid.AutoRotate = true
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	setFlightAnimation("off")
end

local function setupFlightConstraints(hrp: BasePart)
	rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "ClientFlightAttachment"
	rootAttachment.Parent = hrp

	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "ClientFlightVelocity"
	linearVelocity.Attachment0 = rootAttachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.MaxForce = 1e9
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = hrp

	alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "ClientFlightOrientation"
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.Responsiveness = 80
	alignOrientation.MaxTorque = 1e9
	alignOrientation.CFrame = hrp.CFrame
	alignOrientation.Parent = hrp

	orientationCF = hrp.CFrame
	flightVelocity = Vector3.zero
end

local function computeHoverOrientation(targetVelocity: Vector3, dt: number): CFrame
	assert(rootPart)
	local hrp = rootPart
	local forward, right = getCameraBasis(false)

	local referenceForward = Vector3.new(forward.X, 0, forward.Z)
	if referenceForward.Magnitude < 1e-4 then
		referenceForward = hrp.CFrame.LookVector
	end
	referenceForward = referenceForward.Unit

	local base = CFrame.lookAt(hrp.Position, hrp.Position + referenceForward, Vector3.yAxis)

	local localX = targetVelocity:Dot(right)
	local localZ = targetVelocity:Dot(referenceForward)

	local bank = math.rad(-math.clamp(localX / HOVER_SPEED, -1, 1) * HOVER_BANK_DEG)
	local pitch = math.rad(-math.clamp(localZ / HOVER_SPEED, -1, 1) * HOVER_PITCH_DEG)

	local targetCF = base * CFrame.Angles(pitch, 0, bank)
	local alpha = 1 - math.exp(-ORIENTATION_SMOOTHNESS * dt)
	orientationCF = orientationCF:Lerp(targetCF, alpha)

	return orientationCF
end

local function computeFastOrientation(targetVelocity: Vector3, dt: number): CFrame
	assert(rootPart)
	local hrp = rootPart

	local lookDir: Vector3
	local camera = Workspace.CurrentCamera
	local cameraLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
	if cameraLook.Magnitude < 1e-4 then
		cameraLook = hrp.CFrame.LookVector
	end
	cameraLook = cameraLook.Unit

	if targetVelocity.Magnitude > 0.05 then
		local velocityDir = targetVelocity.Unit
		local blended = cameraLook * 0.65 + velocityDir * 0.35
		if blended.Magnitude < 1e-4 then
			lookDir = cameraLook
		else
			lookDir = blended.Unit
		end
	else
		lookDir = cameraLook
	end

	local base = CFrame.lookAt(hrp.Position, hrp.Position + lookDir, Vector3.yAxis)

	local _, right = getCameraBasis(false)
	local strafe = targetVelocity:Dot(right)
	local vertical = targetVelocity.Y

	local bank = math.rad(-math.clamp(strafe / FAST_SPEED, -1, 1) * FAST_BANK_DEG)
	local climbPitch = math.rad(-math.clamp(vertical / FAST_SPEED, -1, 1) * FAST_CLIMB_PITCH_DEG)

	-- Rotate into a horizontal "superman" pose and add subtle dynamic banking/climb
	local targetCF = base * CFrame.Angles(math.rad(-90) + climbPitch, 0, bank)
	local alpha = 1 - math.exp(-ORIENTATION_SMOOTHNESS * dt)
	orientationCF = orientationCF:Lerp(targetCF, alpha)

	return orientationCF
end

local function flightStep(dt: number)
	if mode == "off" then
		return
	end

	if not rootPart or not rootPart.Parent or not humanoid or humanoid.Health <= 0 then
		stopFlight()
		return
	end

	local speed = (mode == "fast") and FAST_SPEED or HOVER_SPEED
	local verticalSpeed = (mode == "fast") and FAST_SPEED * 0.55 or VERTICAL_SPEED

	local moveIntent = getMoveIntent(mode == "fast")
	local desiredVelocity = Vector3.new(
		moveIntent.X * speed,
		moveIntent.Y * verticalSpeed,
		moveIntent.Z * speed
	)

	local alpha = 1 - math.exp(-VELOCITY_SMOOTHNESS * dt)
	flightVelocity = flightVelocity:Lerp(desiredVelocity, alpha)

	if linearVelocity then
		linearVelocity.VectorVelocity = flightVelocity
	end

	if alignOrientation then
		if mode == "hover" then
			alignOrientation.CFrame = computeHoverOrientation(flightVelocity, dt)
		else
			alignOrientation.CFrame = computeFastOrientation(flightVelocity, dt)
		end
	end

	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
end

local function startFlight(startMode: "hover" | "fast")
	local _, hrp, hum = ensureCharacter()
	rootPart = hrp
	humanoid = hum

	destroyFlightConstraints()
	setupFlightConstraints(hrp)

	hum.AutoRotate = false
	hum.PlatformStand = false
	hum:ChangeState(Enum.HumanoidStateType.Physics)

	mode = startMode
	setFlightAnimation(startMode)

	heartbeatConn = RunService.RenderStepped:Connect(flightStep)
end

local function toggleFlight()
	if mode == "off" then
		startFlight("hover")
	else
		stopFlight()
	end
end

local function switchMode()
	if mode == "off" then
		return
	end

	mode = if mode == "hover" then "fast" else "hover"
	setFlightAnimation(mode)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == FLIGHT_TOGGLE_KEY then
		toggleFlight()
		return
	end

	if input.KeyCode == MODE_SWITCH_KEY then
		switchMode()
		return
	end

	if enumToAxis[input.KeyCode] then
		keyState[input.KeyCode] = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if enumToAxis[input.KeyCode] then
		keyState[input.KeyCode] = false
	end
end)

localPlayer.CharacterAdded:Connect(function()
	if mode ~= "off" then
		-- Reinitialize flight on respawn and preserve current mode.
		startFlight(mode == "fast" and "fast" or "hover")
	end
end)
