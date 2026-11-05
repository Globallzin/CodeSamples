--!strict

-- Connected Discord-GitHub
-- Discord: globallzin
-- Roblox: globalzindev

-- One player's run: Countdown → Descending (egg) → Hatching (cutscene) → Ascending (pet) → Finishing.
-- The server owns area progress, integrity (EndsAt), hits, the reward and the grant.
--
-- Design notes:
--  * One RunSession object per run. It is a small state machine: every transition goes through `setPhase`,
--    which mirrors the phase to a player attribute so the client can react without a dedicated remote.
--  * Delayed transitions are scheduled with `after`, which re-checks the phase when the timer fires. A run that
--    was aborted or moved on in the meantime therefore never executes a stale callback.
--  * The owner's client simulates the rolling egg (network ownership), so the server never trusts its movement
--    blindly: progress is sampled from the ball position and implausible jumps are discarded.
--  * Every exit path (finish, caught, abort) funnels into `close`, which is idempotent and releases everything
--    the session holds (connections, guardian, hold lock) before notifying the owner service via `onEnded`.
local RunSession = {}
RunSession.__index = RunSession

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MinigameConfig = require(ReplicatedStorage.Shared.Services.Minigame.MinigameConfig)
local MinigameUtils = require(ReplicatedStorage.Shared.Services.Minigame.MinigameUtils)
local Course = require(ReplicatedStorage.Shared.Services.Minigame.Course)
local BackpackServer = require(ServerScriptService.Services.Backpack.BackpackServer)
local MorphServer = require(script.Parent.MorphServer)
local ChaseServer = require(script.Parent.ChaseServer)
local AvatarRagdollServer = require(script.Parent.AvatarRagdollServer)
local GuardianServer = require(script.Parent.GuardianServer)
local ObstacleServer = require(script.Parent.ObstacleServer)
local RewardServer = require(script.Parent.RewardServer)

local phases = MinigameConfig.phases
local attributes = MinigameConfig.attributes
local runConfig = MinigameConfig.run
local guardianConfig = MinigameConfig.guardian
-- Upper bound (seconds) for the owner's client to stream the lobby in before the character is released there.
local LOBBY_STREAM_TIMEOUT = 5
-- Longest frame delta fed to the chase simulation; a server hitch must not teleport the guardian forward.
local MAX_ASCENT_DELTA = 0.25
-- Extra studs of slack on the movement plausibility check, absorbing physics jitter between two samples.
local PLAUSIBLE_MOVE_SLACK = 8
-- Progress along the last area at which the egg counts as having reached the bottom.
local BOTTOM_PROGRESS = 0.995

-- Everything the owning service injects, so the session never reaches for globals of its own.
export type Context = {
	course: Course.Course,
	obstacles: ObstacleServer.ObstacleServer,
	networker: any,
	startCFrame: CFrame,
	finishLine: BasePart,
	-- Where a caught runner lands: inside the lobby, just past the start line.
	lobbyCFrame: CFrame,
	guardians: GuardianServer.GuardianServer,
	floors: { Instance },
	-- Pass effects resolved when the run starts (luck, Shiny Hunter, Guardian Shield).
	modifiers: { luck: number, mutation: number, guardianPace: number },
	-- Called with the lost pet when a guardian catches the runner (Save Pet offer).
	onCaught: (pet: any) -> (),
	onEnded: (session: any, reason: string) -> (),
}

type State = {
	player: Player,
	character: Model,
	context: Context,
	-- One of MinigameConfig.phases, or nil before the run starts and after it is closed.
	phase: string?,
	-- Set once by `close`; every delayed callback and update loop checks it before acting.
	ended: boolean,
	morph: MorphServer.Morph?,
	speedStat: number,
	duration: number,
	rollSpeed: number,
	walkSpeed: number,
	-- Server time at which the egg breaks on its own. Obstacle hits pull it closer.
	endsAt: number,
	areaIndex: number,
	-- Furthest progress (0..1) reached inside the current area; it never goes backwards.
	progress: number,
	crackStage: number,
	lastPosition: Vector3?,
	lastSampleAt: number,
	-- Per-obstacle cooldowns so one overlap does not hit on every tick.
	hitCooldowns: { [Instance]: number },
	-- Invulnerability window after a hit.
	graceUntil: number,
	reward: RewardServer.Reward?,
	chaser: Model?,
	chaseArea: number?,
	chase: ChaseServer.Chase?,
	lastUpdateAt: number,
	connections: { RBXScriptConnection },
}
export type RunSession = typeof(setmetatable({} :: State, RunSession))

function RunSession.new(player: Player, character: Model, speedStat: number, context: Context): RunSession
	return setmetatable(
		{
			player = player,
			character = character,
			context = context,
			phase = nil,
			ended = false,
			morph = nil,
			speedStat = speedStat,
			-- All speed-derived values are resolved once, so a run is consistent even if the stat changes mid-run.
			duration = MinigameUtils.getRunDuration(speedStat),
			rollSpeed = MinigameUtils.getRollSpeed(speedStat),
			walkSpeed = MinigameUtils.getWalkSpeed(speedStat),
			endsAt = 0,
			areaIndex = 1,
			progress = 0,
			crackStage = 0,
			lastPosition = nil,
			lastSampleAt = 0,
			hitCooldowns = {},
			graceUntil = 0,
			reward = nil,
			chaser = nil,
			chaseArea = nil,
			chase = nil,
			lastUpdateAt = 0,
			connections = {},
		} :: State,
		RunSession
	)
end

-- Single entry point for phase changes: the attribute lets the client drive its HUD and camera from it.
function RunSession.setPhase(self: RunSession, phase: string?)
	self.phase = phase
	self.player:SetAttribute(attributes.phase, phase)
end

-- Fires a client event unless the player already left (the networker would error on a missing player).
function RunSession.notify(self: RunSession, method: string, payload: { [string]: any })
	if self.player.Parent then
		self.context.networker:fire(self.player, method, payload)
	end
end

-- Runs fn after delay only if the run is still in the expected phase.
-- The phase check is what makes timers safe: an abort or an earlier transition invalidates them for free.
function RunSession.after(self: RunSession, delay: number, expectedPhase: string, fn: () -> ())
	task.delay(delay, function()
		if not self.ended and self.phase == expectedPhase then
			fn()
		end
	end)
end

-- Attributes on the egg rig replicate to every client, which animates the egg from them (cracks, timers).
function RunSession.setRigAttribute(self: RunSession, name: string, value: any)
	local rig = self.morph and self.morph.rig
	if rig then
		rig.model:SetAttribute(name, value)
	end
end

function RunSession.start(self: RunSession): boolean
	local morph = MorphServer.begin(self.player, self.character)
	if not morph then
		return false
	end
	self.morph = morph

	BackpackServer:setHoldLocked(self.player, true)
	local rig = MorphServer.buildEggRig(morph, self.context.startCFrame, MinigameConfig.areas[1].rarity)
	-- Server time, not os.clock: it is the one clock the server and every client agree on.
	local startsAt = workspace:GetServerTimeNow() + runConfig.countdown
	rig.model:SetAttribute(attributes.startsAt, startsAt)
	rig.model:SetAttribute(attributes.duration, self.duration)
	rig.model:SetAttribute(attributes.crackStage, 0)
	self:setPhase(phases.countdown)

	-- Both connections feed the same abort path, so a dead or removed character can never strand the run.
	table.insert(
		self.connections,
		morph.humanoid.Died:Connect(function()
			self:abort("died")
		end)
	)
	table.insert(
		self.connections,
		self.character.AncestryChanged:Connect(function()
			if not self.character:IsDescendantOf(workspace) then
				self:abort("character_removed")
			end
		end)
	)

	self:notify("runStarted", {
		startsAt = startsAt,
		duration = self.duration,
		rollSpeed = self.rollSpeed,
	})
	self:after(runConfig.countdown, phases.countdown, function()
		self:beginDescent()
	end)
	return true
end

-- The countdown is over: the integrity clock starts and the egg is released onto the course.
function RunSession.beginDescent(self: RunSession)
	local morph = self.morph :: MorphServer.Morph
	self.endsAt = workspace:GetServerTimeNow() + self.duration
	self:setRigAttribute(attributes.endsAt, self.endsAt)
	MorphServer.setEggAnchored(morph, false)
	self.lastSampleAt = os.clock()
	self.lastPosition = morph.rig and morph.rig.ball.Position
	self:setPhase(phases.descending)
end

-- Driven by the owning service on a fixed tick; only the phases that need per-tick work are handled here.
function RunSession.update(self: RunSession, now: number)
	if self.ended then
		return
	elseif self.phase == phases.descending then
		self:updateDescent(now)
	elseif self.phase == phases.ascending then
		local deltaTime = if self.lastUpdateAt > 0 then math.min(now - self.lastUpdateAt, MAX_ASCENT_DELTA) else 0
		self.lastUpdateAt = now
		self:updateAscent(deltaTime)
	end
end

-- Converts the ball position into (area, progress). The client simulates the ball, so every sample is
-- sanity-checked against the maximum plausible speed before it may advance the run.
function RunSession.trackProgress(self: RunSession, position: Vector3)
	local clock = os.clock()
	-- Clamp the elapsed time so two samples in the same frame cannot make the allowed distance zero.
	local elapsed = math.max(clock - self.lastSampleAt, 1 / runConfig.tickRate)
	local moved = if self.lastPosition then (position - self.lastPosition).Magnitude else 0
	self.lastPosition = position
	self.lastSampleAt = clock
	-- Teleport-like jumps never count as progress.
	if moved > runConfig.maxPlausibleSpeed * elapsed + PLAUSIBLE_MOVE_SLACK then
		return
	end

	local index, progress = self.context.course:locate(position)
	if index == self.areaIndex then
		self.progress = math.max(self.progress, progress)
	elseif index == self.areaIndex + 1 then
		-- Only the very next area counts: skipping areas (or going back) can not be used to shortcut the course.
		self.areaIndex = index
		self.progress = progress
		local area = MinigameConfig.areas[index]
		if area and self.morph then
			MorphServer.setEggRarity(self.morph, area.rarity)
		end
		self:notify("areaReached", { areaIndex = index })
	end
end

-- An obstacle hit shortens the run instead of dealing health damage: it pulls `endsAt` closer.
function RunSession.applyHits(self: RunSession, position: Vector3, now: number)
	local config = MinigameConfig.obstacles
	if now < self.graceUntil then
		return
	end
	local radius = MinigameConfig.egg.ballDiameter / 2 + config.hitPadding
	for _, hit in self.context.obstacles:findHits(position, radius, now) do
		if (self.hitCooldowns[hit.instance] or 0) <= now then
			self.hitCooldowns[hit.instance] = now + config.hitCooldown
			self.graceUntil = now + config.hitGrace
			-- A single hit can never remove more than maxHitFraction of the run, however heavy the obstacle.
			self.endsAt -= math.min(hit.damage * config.damagePerWeight, self.duration * config.maxHitFraction)
			self:setRigAttribute(attributes.endsAt, self.endsAt)
			self:setRigAttribute(attributes.lastHitAt, now)
			-- One hit per tick is enough: the grace window would reject the others anyway.
			break
		end
	end
end

-- The three ways the descent ends: time ran out, the bottom was reached, or the egg fell off the course.
function RunSession.updateDescent(self: RunSession, now: number)
	local rig = self.morph and self.morph.rig
	if not rig or not rig.ball.Parent then
		self:abort("egg_lost")
		return
	end

	local position = rig.ball.Position
	self:trackProgress(position)
	self:applyHits(position, now)

	local remaining = self.endsAt - now
	-- The crack stage only ever increases, so the replicated attribute is written at most once per stage.
	local stage = MinigameUtils.getCrackStage(remaining / self.duration)
	if stage > self.crackStage then
		self.crackStage = stage
		self:setRigAttribute(attributes.crackStage, stage)
	end

	local course = self.context.course
	if remaining <= 0 then
		self:breakEgg("time")
	elseif self.areaIndex >= course:getAreaCount() and self.progress >= BOTTOM_PROGRESS then
		self:breakEgg("bottom")
	elseif position.Y < course:getLowestY() - MinigameConfig.world.fallDistance then
		self:breakEgg("fell")
	end
end

-- The reward is rolled here, on the server, from where the egg broke; the client only plays the cutscene.
function RunSession.breakEgg(self: RunSession, cause: string)
	local morph = self.morph :: MorphServer.Morph
	self:setPhase(phases.hatching)
	MorphServer.setEggAnchored(morph, true)
	self:setRigAttribute(attributes.crackStage, #runConfig.crackStages)
	self:setRigAttribute(attributes.broken, true)

	local reward = RewardServer.roll(self.areaIndex, self.progress, self.context.modifiers)
	self.reward = reward
	self:notify("playHatch", {
		pet = reward.pet,
		cause = cause,
		areaIndex = reward.areaIndex,
		progress = reward.progress,
		minimumRarity = reward.minimumRarity,
	})
	self:after(MinigameConfig.hatch.cutsceneDuration, phases.hatching, function()
		self:wakeGuardian()
	end)
end

-- The area's guardian wakes up (the owner's camera visits it) before the pet avatar takes over.
function RunSession.wakeGuardian(self: RunSession)
	local rig = self.morph and self.morph.rig
	local parent = if rig and rig.model.Parent then rig.model.Parent else workspace
	local chaser = self.context.guardians:createChaser(self.areaIndex, self.player.UserId, parent)
	-- Areas without a free guardian skip straight to the ascent.
	if not chaser then
		self:beginAscent()
		return
	end
	self.chaser = chaser
	-- Remembered separately from areaIndex: the chaser must be released against the area it was taken from.
	self.chaseArea = self.areaIndex
	chaser:SetAttribute(guardianConfig.attributes.wakeAt, workspace:GetServerTimeNow())
	self:notify("guardianWake", { chaser = chaser, wakeDuration = guardianConfig.wakeDuration })
	self:after(guardianConfig.wakeDuration, phases.hatching, function()
		self:beginAscent()
	end)
end

-- The egg becomes the pet avatar and the uphill run begins; a guardian, if any, starts chasing.
function RunSession.beginAscent(self: RunSession)
	local morph = self.morph :: MorphServer.Morph
	local reward = self.reward :: RewardServer.Reward
	local rig = morph.rig
	local position = if rig then rig.ball.Position else morph.root.Position
	local uphill = -self.context.course:getDownhill(self.areaIndex)
	local standPosition = position + Vector3.new(0, 2, 0)

	if
		not MorphServer.becomePet(
			morph,
			reward.pet,
			CFrame.lookAt(standPosition, standPosition + uphill),
			self.walkSpeed
		)
	then
		self:abort("morph_failed")
		return
	end
	self:setPhase(phases.ascending)
	if self.chaser then
		local area = self.chaseArea :: number
		local chaseUphill = -self.context.course:getDownhill(area)
		local distanceToFinish = self.context.course:getDistanceToFinish(self.context.finishLine, standPosition)
		local chase = ChaseServer.new(
			self.chaser,
			area,
			self.speedStat,
			self.walkSpeed,
			chaseUphill,
			self.context.floors,
			standPosition,
			distanceToFinish,
			self.context.modifiers.guardianPace
		)
		chase:begin()
		self.chase = chase
	end
	self:notify("ascentStarted", { walkSpeed = self.walkSpeed, chaser = self.chaser })
end

-- The chase is resolved before the finish check, so a runner caught on the line still counts as caught.
function RunSession.updateAscent(self: RunSession, deltaTime: number)
	local morph = self.morph :: MorphServer.Morph
	if self.chase and self.chase:update(deltaTime, morph.root.Position) then
		self:caught()
		return
	end
	if self.context.course:hasCrossedFinish(self.context.finishLine, morph.root.Position) then
		self:finish()
	end
end

-- The runner crossed the finish line: the guardian stops and a short transition plays before the grant.
function RunSession.finish(self: RunSession)
	local morph = self.morph :: MorphServer.Morph
	self:setPhase(phases.finishing)
	if self.chase then
		self.chase:stop()
	end
	if morph.avatar then
		morph.avatar:SetAttribute(attributes.finishing, true)
	end
	self:notify("runFinishing", {})
	self:after(MinigameConfig.finish.transitionDuration, phases.finishing, function()
		self:complete()
	end)
end

-- The guardian got the runner: the pet avatar is flung, and while the owner's camera glides back to the
-- lobby the character is restored and teleported there (the pet is lost, like dying mid-ascent).
function RunSession.caught(self: RunSession)
	local morph = self.morph :: MorphServer.Morph
	self:setPhase(phases.caught)
	local chase = self.chase :: ChaseServer.Chase
	chase:stop()
	-- Fling direction is flat (Y = 0) so the ragdoll slides away from the guardian instead of launching upward.
	local away = morph.root.Position - chase.position
	AvatarRagdollServer.ragdoll(morph, Vector3.new(away.X, 0, away.Z))
	self.context.onCaught((self.reward :: RewardServer.Reward).pet)
	self:notify("runCaught", {
		position = morph.root.Position,
		guardianPosition = chase.position,
		lobbyCFrame = self.context.lobbyCFrame,
		ragdollTime = guardianConfig.ragdollTime,
		glideTime = guardianConfig.returnGlideTime,
	})
	-- StreamingEnabled: deep in the course the lobby is streamed out on the owner's client, which simulates its
	-- character; landing there unanchored before the floor arrives drops it through the world.
	-- The stream request runs in parallel with the ragdoll/glide; the release below waits on it (bounded).
	local lobbyPosition = self.context.lobbyCFrame.Position
	local lobbyStreamed = false
	local waiter: thread? = nil
	local function wakeWaiter()
		-- Whichever of "stream finished" and "timeout" fires first resumes the waiter; the other is a no-op.
		local thread = waiter
		waiter = nil
		if thread then
			task.spawn(thread)
		end
	end
	task.spawn(function()
		local ok, err = pcall(self.player.RequestStreamAroundAsync, self.player, lobbyPosition, LOBBY_STREAM_TIMEOUT)
		if not ok then
			warn(`[RunSession] Lobby stream request failed for {self.player.Name}: {err}`)
		end
		lobbyStreamed = true
		wakeWaiter()
	end)
	self:after(
		guardianConfig.ragdollTime + guardianConfig.returnGlideTime * guardianConfig.teleportAtGlide,
		phases.caught,
		function()
			MorphServer.restore(morph)
			-- Teleport anchored; release once the lobby is streamed to the owner (bounded wait).
			if morph.character.Parent then
				morph.character:PivotTo(self.context.lobbyCFrame)
			end
			if not lobbyStreamed then
				waiter = coroutine.running()
				task.delay(LOBBY_STREAM_TIMEOUT, wakeWaiter)
				coroutine.yield()
			end
			-- The player may have left while this thread was waiting.
			if self.ended then
				return
			end
			morph.root.AssemblyLinearVelocity = Vector3.zero
			morph.root.Anchored = false
			self:close("caught")
		end
	)
end

-- Grants the pet. If the backpack is full the run still closes cleanly, with a distinct reason for the UI.
function RunSession.complete(self: RunSession)
	local morph = self.morph :: MorphServer.Morph
	local pet = (self.reward :: RewardServer.Reward).pet
	MorphServer.restore(morph)

	-- The hold lock is released by `close`; setHeldItem is not affected by it.
	local itemId = BackpackServer:addPet(self.player, pet)
	if itemId then
		BackpackServer:setHeldItem(self.player, itemId)
	end
	self:notify("runCompleted", { pet = pet, itemId = itemId })
	self:close(if itemId then "completed" else "backpack_full")
end

-- Early exit (death, disconnect, broken rig). The character is restored and the owner is told whether a
-- rolled pet was lost, so the client can explain it.
function RunSession.abort(self: RunSession, reason: string)
	if self.ended then
		return
	end
	if self.morph then
		MorphServer.restore(self.morph)
	end
	self:notify("runAborted", { reason = reason, lostPet = self.reward ~= nil })
	self:close(reason)
end

-- Idempotent teardown shared by every exit path. After `ended` is set no delayed callback can act anymore.
function RunSession.close(self: RunSession, reason: string)
	if self.ended then
		return
	end
	self.ended = true
	if self.chaseArea then
		self.context.guardians:releaseChaser(self.chaseArea, self.chaser)
		self.chaser = nil
		self.chaseArea = nil
	end
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	BackpackServer:setHoldLocked(self.player, false)
	self:setPhase(nil)
	self.context.onEnded(self, reason)
end

return RunSession
