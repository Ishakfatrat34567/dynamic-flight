--!strict
-- Dynamic Flight System (Client-Only)
-- Controls:
--   F = Toggle flight (Hover On/Off)
--   E = Switch Hover <-> Fast while flight is active
--   WASD = Directional movement
--   Space / LeftControl = Up / Down

--// Services
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

--// Config: input + base speeds
local FLIGHT_TOGGLE_KEY = Enum.KeyCode.F
local MODE_SWITCH_KEY = Enum.KeyCode.E

local HOVER_SPEED = 16
local HOVER_VERTICAL_SPEED = 16
local FAST_SPEED = 150
local FAST_VERTICAL_SPEED = 92

--// Config: movement feel (momentum / inertia)
local HOVER_ACCEL = 14
local HOVER_DECEL = 16
local FAST_ACCEL = 18
local FAST_DECEL = 20 -- very tight slowdown with slight residual drift
local FAST_TURN_RESPONSE = 12
local FAST_MOMENTUM_KEEP = 0.05
local FAST_TO_HOVER_SPEED = 40

--// Config: orientation / tilt
local ORIENTATION_SMOOTHNESS = 10
local HOVER_BANK_DEG = 18
local HOVER_PITCH_DEG = 14
local FAST_BANK_DEG = 26
local FAST_CLIMB_PITCH_DEG = 10

--// Config: hover polish
local HOVER_BOB_FREQ = 1.9
local HOVER_BOB_SPEED = 1.0

--// Config: sonic / cinematic effects (client visual only)
local SONIC_THRESHOLD = 120
local SONIC_BOOM_COOLDOWN = 0.65
local FOV_BOOST_AT_MAX = 16
local SPEED_LINES_MAX_RATE = 170
local SPEED_LINES_MIN_RATE = 18

--// Input axis mapping
local axisByKey: {[Enum.KeyCode]: Vector3} = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	[Enum.KeyCode.Space] = Vector3.new(0, 1, 0),
	[Enum.KeyCode.LeftControl] = Vector3.new(0, -1, 0),
}

--// Runtime state
local mode = "off" :: "off" | "hover" | "fast"
local keyState: {[Enum.KeyCode]: boolean} = {}

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

local rootAttachment: Attachment? = nil
local linearVelocity: LinearVelocity? = nil
local alignOrientation: AlignOrientation? = nil

local speedAttachment: Attachment? = nil
local speedLines: ParticleEmitter? = nil
local boomEmitter: ParticleEmitter? = nil
local leftTrailAttachment: Attachment? = nil
local rightTrailAttachment: Attachment? = nil
local windTrail: Trail? = nil

local currentVelocity = Vector3.zero
local orientationCF = CFrame.new()
local baseFov = 70
local lastBoomTime = 0
local wasSupersonic = false
local lastHadInput = false

local animateScript: LocalScript? = nil
local animateWasDisabled: boolean? = nil
local animationTracks: {[string]: AnimationTrack} = {}
local activeAnimationMode = "off" :: "off" | "hover" | "fast"

local stepConnection: RBXScriptConnection? = nil

--// Character / camera helpers
local function ensureCharacter()
	local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	local hum = character:WaitForChild("Humanoid") :: Humanoid
	return character, hrp, hum
end

local function getCameraVectors(includePitch: boolean): (Vector3, Vector3, Vector3)
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)
	end

	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector

	local forward = includePitch and look or Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 1e-4 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end

	local rightVector = includePitch and right or Vector3.new(right.X, 0, right.Z)
	if rightVector.Magnitude < 1e-4 then
		rightVector = Vector3.new(1, 0, 0)
	else
		rightVector = rightVector.Unit
	end

	return forward, rightVector, Vector3.yAxis
end

local function getInputIntent(includePitch: boolean): Vector3
	local forward, right, up = getCameraVectors(includePitch)
	local intent = Vector3.zero

	for keyCode, axis in pairs(axisByKey) do
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

--// Animation helpers (client-only)
local function stopFlightAnimationTracks()
	for _, track in pairs(animationTracks) do
		if track.IsPlaying then
			track:Stop(0.15)
		end
		track:Destroy()
	end
	table.clear(animationTracks)
end

local function getAnimationFromAnimate(character: Model, folderName: string, animationName: string): Animation?
	local animate = character:FindFirstChild("Animate")
	if not animate then
		return nil
	end

	local folder = animate:FindFirstChild(folderName)
	if not folder then
		return nil
	end

	local animation = folder:FindFirstChild(animationName)
	if animation and animation:IsA("Animation") then
		return animation
	end

	return nil
end

local function getHoverIdleAnimation(character: Model): Animation
	local idle1 = getAnimationFromAnimate(character, "idle", "Animation1")
	if idle1 then
		return idle1
	end

	local idle2 = getAnimationFromAnimate(character, "idle", "Animation2")
	if idle2 then
		return idle2
	end

	local fallback = Instance.new("Animation")
	fallback.AnimationId = "rbxassetid://507766388"
	return fallback
end

local function getFastFallingAnimation(character: Model): Animation
	local fall = getAnimationFromAnimate(character, "fall", "FallAnim")
	if fall then
		return fall
	end

	local fallback = Instance.new("Animation")
	fallback.AnimationId = "rbxassetid://507767968"
	return fallback
end

local function setFlightAnimation(targetMode: "off" | "hover" | "fast")
	if activeAnimationMode == targetMode and targetMode ~= "off" then
		return
	end

	local character = localPlayer.Character
	if targetMode == "off" then
		stopFlightAnimationTracks()
		if character then
			animateScript = character:FindFirstChild("Animate") :: LocalScript?
		end
		if animateScript and animateWasDisabled ~= nil then
			animateScript.Disabled = animateWasDisabled
		end
		animateWasDisabled = nil
		activeAnimationMode = "off"
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

	stopFlightAnimationTracks()

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = if targetMode == "hover" then getHoverIdleAnimation(character) else getFastFallingAnimation(character)
	local track = animator:LoadAnimation(animation)
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	track:Play(0.15, 1, 1)
	animationTracks[targetMode] = track
	activeAnimationMode = targetMode

	if animation.Parent == nil then
		animation:Destroy()
	end
end

--// Effects
local function createEffects(hrp: BasePart)
	speedAttachment = Instance.new("Attachment")
	speedAttachment.Name = "ClientFlightSpeedAttachment"
	speedAttachment.Parent = hrp

	speedLines = Instance.new("ParticleEmitter")
	speedLines.Name = "ClientFlightSpeedLines"
	speedLines.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	speedLines.LightEmission = 1
	speedLines.LightInfluence = 0
	speedLines.Color = ColorSequence.new(Color3.fromRGB(215, 235, 255))
	speedLines.Lifetime = NumberRange.new(0.18, 0.32)
	speedLines.Speed = NumberRange.new(32, 55)
	speedLines.Rate = 0
	speedLines.RotSpeed = NumberRange.new(-180, 180)
	speedLines.SpreadAngle = Vector2.new(8, 8)
	speedLines.VelocityInheritance = 0.6
	speedLines.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	speedLines.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	speedLines.Parent = speedAttachment

	boomEmitter = Instance.new("ParticleEmitter")
	boomEmitter.Name = "ClientFlightSonicBoom"
	boomEmitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	boomEmitter.Lifetime = NumberRange.new(0.25, 0.4)
	boomEmitter.Speed = NumberRange.new(0, 0)
	boomEmitter.Rate = 0
	boomEmitter.LightEmission = 1
	boomEmitter.Color = ColorSequence.new(Color3.fromRGB(210, 235, 255))
	boomEmitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	boomEmitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.25, 5.5),
		NumberSequenceKeypoint.new(1, 10),
	})
	boomEmitter.Rotation = NumberRange.new(0, 360)
	boomEmitter.RotSpeed = NumberRange.new(-80, 80)
	boomEmitter:Clear()
	boomEmitter.Parent = speedAttachment

	leftTrailAttachment = Instance.new("Attachment")
	leftTrailAttachment.Name = "ClientFlightTrailLeft"
	leftTrailAttachment.Position = Vector3.new(-1.2, 0, 0)
	leftTrailAttachment.Parent = hrp

	rightTrailAttachment = Instance.new("Attachment")
	rightTrailAttachment.Name = "ClientFlightTrailRight"
	rightTrailAttachment.Position = Vector3.new(1.2, 0, 0)
	rightTrailAttachment.Parent = hrp

	windTrail = Instance.new("Trail")
	windTrail.Name = "ClientFlightWindTrail"
	windTrail.Attachment0 = leftTrailAttachment
	windTrail.Attachment1 = rightTrailAttachment
	windTrail.Color = ColorSequence.new(Color3.fromRGB(190, 225, 255))
	windTrail.LightEmission = 1
	windTrail.Lifetime = 0.16
	windTrail.MinLength = 0.1
	windTrail.FaceCamera = true
	windTrail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	windTrail.Enabled = false
	windTrail.Parent = hrp
end

local function destroyEffects()
	if speedLines then speedLines:Destroy() speedLines = nil end
	if boomEmitter then boomEmitter:Destroy() boomEmitter = nil end
	if windTrail then windTrail:Destroy() windTrail = nil end
	if leftTrailAttachment then leftTrailAttachment:Destroy() leftTrailAttachment = nil end
	if rightTrailAttachment then rightTrailAttachment:Destroy() rightTrailAttachment = nil end
	if speedAttachment then speedAttachment:Destroy() speedAttachment = nil end

	local camera = Workspace.CurrentCamera
	if camera then
		camera.FieldOfView = baseFov
	end

	wasSupersonic = false
	lastBoomTime = 0
end

local function updateEffects(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local speed = currentVelocity.Magnitude
	local fastSpeedRatio = math.clamp(speed / FAST_SPEED, 0, 1)
	local isFastMode = mode == "fast"
	local isSupersonic = isFastMode and speed >= SONIC_THRESHOLD

	if speedLines then
		if isFastMode then
			local rate = SPEED_LINES_MIN_RATE + (SPEED_LINES_MAX_RATE - SPEED_LINES_MIN_RATE) * fastSpeedRatio
			speedLines.Rate = rate
		else
			speedLines.Rate = 0
		end
	end

	if windTrail then
		windTrail.Enabled = isFastMode and speed > SONIC_THRESHOLD * 0.8
	end

	if boomEmitter and isSupersonic and ((not wasSupersonic) or (os.clock() - lastBoomTime >= SONIC_BOOM_COOLDOWN)) then
		boomEmitter:Emit(24)
		lastBoomTime = os.clock()
	end
	wasSupersonic = isSupersonic

	local targetFov = baseFov + (isFastMode and (FOV_BOOST_AT_MAX * fastSpeedRatio) or 0)
	local fovAlpha = 1 - math.exp(-8 * dt)
	camera.FieldOfView = camera.FieldOfView + (targetFov - camera.FieldOfView) * fovAlpha
end

--// Flight constraints / lifecycle
local function destroyFlightConstraints()
	if stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end

	if linearVelocity then linearVelocity:Destroy() linearVelocity = nil end
	if alignOrientation then alignOrientation:Destroy() alignOrientation = nil end
	if rootAttachment then rootAttachment:Destroy() rootAttachment = nil end

	destroyEffects()
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
	rootAttachment.Name = "ClientFlightRootAttachment"
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
	alignOrientation.MaxTorque = 1e9
	alignOrientation.Responsiveness = 80
	alignOrientation.RigidityEnabled = false
	alignOrientation.CFrame = hrp.CFrame
	alignOrientation.Parent = hrp

	currentVelocity = Vector3.zero
	orientationCF = hrp.CFrame
	createEffects(hrp)
end

--// Orientation logic
local function computeHoverOrientation(dt: number): CFrame
	assert(rootPart)
	local hrp = rootPart

	local forward, right = getCameraVectors(false)
	local refForward = Vector3.new(forward.X, 0, forward.Z)
	if refForward.Magnitude < 1e-4 then
		refForward = hrp.CFrame.LookVector
	end
	refForward = refForward.Unit

	local base = CFrame.lookAt(hrp.Position, hrp.Position + refForward, Vector3.yAxis)
	local localX = currentVelocity:Dot(right)
	local localZ = currentVelocity:Dot(refForward)

	local bank = math.rad(-math.clamp(localX / HOVER_SPEED, -1, 1) * HOVER_BANK_DEG)
	local pitch = math.rad(-math.clamp(localZ / HOVER_SPEED, -1, 1) * HOVER_PITCH_DEG)

	local hoverBobbingPitch = math.rad(math.sin(os.clock() * HOVER_BOB_FREQ) * 1.25)
	local target = base * CFrame.Angles(pitch + hoverBobbingPitch, 0, bank)

	local alpha = 1 - math.exp(-ORIENTATION_SMOOTHNESS * dt)
	orientationCF = orientationCF:Lerp(target, alpha)
	return orientationCF
end

local function computeFastOrientation(dt: number): CFrame
	assert(rootPart)
	local hrp = rootPart

	local camera = Workspace.CurrentCamera
	local cameraLook = camera and camera.CFrame.LookVector or hrp.CFrame.LookVector
	if cameraLook.Magnitude < 1e-4 then
		cameraLook = hrp.CFrame.LookVector
	end
	cameraLook = cameraLook.Unit

	local moveDir = if currentVelocity.Magnitude > 0.01 then currentVelocity.Unit else cameraLook
	local blended = cameraLook * 0.6 + moveDir * 0.4
	local lookDir = if blended.Magnitude > 1e-4 then blended.Unit else cameraLook

	local base = CFrame.lookAt(hrp.Position, hrp.Position + lookDir, Vector3.yAxis)
	local _, right = getCameraVectors(false)

	local strafe = currentVelocity:Dot(right)
	local vertical = currentVelocity.Y

	local bank = math.rad(-math.clamp(strafe / FAST_SPEED, -1, 1) * FAST_BANK_DEG)
	local climbPitch = math.rad(-math.clamp(vertical / FAST_SPEED, -1, 1) * FAST_CLIMB_PITCH_DEG)

	local target = base * CFrame.Angles(math.rad(-90) + climbPitch, 0, bank)
	local alpha = 1 - math.exp(-ORIENTATION_SMOOTHNESS * dt)
	orientationCF = orientationCF:Lerp(target, alpha)
	return orientationCF
end

--// Movement integration
local function updateVelocity(dt: number)
	local isFast = mode == "fast"
	local intent = getInputIntent(isFast)
	local hasInput = intent.Magnitude > 0.001
	lastHadInput = hasInput

	local moveSpeed = isFast and FAST_SPEED or HOVER_SPEED
	local verticalSpeed = isFast and FAST_VERTICAL_SPEED or HOVER_VERTICAL_SPEED
	local desired = Vector3.new(intent.X * moveSpeed, intent.Y * verticalSpeed, intent.Z * moveSpeed)

	if (not isFast) and math.abs(intent.Y) < 0.001 then
		desired += Vector3.new(0, math.sin(os.clock() * HOVER_BOB_FREQ) * HOVER_BOB_SPEED, 0)
	end

	local accel = isFast and FAST_ACCEL or HOVER_ACCEL
	local decel = isFast and FAST_DECEL or HOVER_DECEL

	if hasInput then
		if isFast then
			local preserved = currentVelocity * FAST_MOMENTUM_KEEP
			local steerTarget = desired + preserved
			if steerTarget.Magnitude > FAST_SPEED then
				steerTarget = steerTarget.Unit * FAST_SPEED
			end
			local steerAlpha = 1 - math.exp(-FAST_TURN_RESPONSE * dt)
			desired = currentVelocity:Lerp(steerTarget, steerAlpha)
		end

		local alpha = 1 - math.exp(-accel * dt)
		currentVelocity = currentVelocity:Lerp(desired, alpha)
	else
		local alpha = 1 - math.exp(-decel * dt)
		currentVelocity = currentVelocity:Lerp(Vector3.zero, alpha)
	end
end

local function onStep(dt: number)
	if mode == "off" then
		return
	end

	if not rootPart or not rootPart.Parent or not humanoid or humanoid.Health <= 0 then
		stopFlight()
		return
	end

	updateVelocity(dt)

	if mode == "fast" and (not lastHadInput) and currentVelocity.Magnitude <= FAST_TO_HOVER_SPEED then
		mode = "hover"
		setFlightAnimation("hover")
	end

	if linearVelocity then
		linearVelocity.VectorVelocity = currentVelocity
	end

	if alignOrientation then
		alignOrientation.CFrame = if mode == "hover" then computeHoverOrientation(dt) else computeFastOrientation(dt)
	end

	updateEffects(dt)
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

local function startFlight(startMode: "hover" | "fast")
	local _, hrp, hum = ensureCharacter()
	rootPart = hrp
	humanoid = hum

	baseFov = (Workspace.CurrentCamera and Workspace.CurrentCamera.FieldOfView) or 70

	destroyFlightConstraints()
	setupFlightConstraints(hrp)
	stopFlightAnimationTracks()
	activeAnimationMode = "off"
	animateWasDisabled = nil

	hum.AutoRotate = false
	hum.PlatformStand = false
	hum:ChangeState(Enum.HumanoidStateType.Physics)

	mode = startMode
	setFlightAnimation(startMode)
	stepConnection = RunService.RenderStepped:Connect(onStep)
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

--// Input events
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

	if axisByKey[input.KeyCode] then
		keyState[input.KeyCode] = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if axisByKey[input.KeyCode] then
		keyState[input.KeyCode] = false
	end
end)

localPlayer.CharacterAdded:Connect(function()
	if mode ~= "off" then
		startFlight(mode == "fast" and "fast" or "hover")
	end
end)
