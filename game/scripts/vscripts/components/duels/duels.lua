local HeroState = require("components/duels/savestate")
local SafeTeleportAll = require("components/duels/teleport").SafeTeleportAll

LinkLuaModifier("modifier_out_of_duel", "modifiers/modifier_out_of_duel.lua", LUA_MODIFIER_MOTION_NONE)

DUEL_IS_STARTING = 21

Duels = Duels or {}
local zoneNames = {
  "duel_1",
  "duel_2",
  "duel_3",
  "duel_4",
}

local DuelPreparingEvent = Event()
local DuelStartEvent = Event()
local DuelEndEvent = Event()

Duels.onStart = DuelStartEvent.listen
Duels.onPreparing = DuelPreparingEvent.listen
Duels.onEnd = DuelEndEvent.listen

function Duels:Init ()
  DebugPrint('Init duels')

  self.currentDuel = nil
  iter(zoneNames):foreach(partial(self.RegisterZone, self))

  GameEvents:OnHeroDied(function (keys)
    self:CheckDuelStatus(keys)
  end)

  GameEvents:OnPlayerReconnect(function (keys)
-- [VScript] [components\duels\duels:64] PlayerID: 1
-- [VScript] [components\duels\duels:64] name: Minnakht
-- [VScript] [components\duels\duels:64] networkid: [U:1:53917791]
-- [VScript] [components\duels\duels:64] reason: 2
-- [VScript] [components\duels\duels:64] splitscreenplayer: -1
-- [VScript] [components\duels\duels:64] userid: 3
-- [VScript] [components\duels\duels:64] xuid: 76561198014183519
    local playerID = keys.PlayerID
    if playerID then
      local hero = PlayerResource:GetSelectedHeroEntity(playerID)
      if hero and not self.currentDuel then
        hero:SetRespawnsDisabled(false)
        if hero:IsAlive() then
          hero:RemoveModifierByName("modifier_out_of_duel")
        else
          hero:RespawnHero(false, false)
          hero = PlayerResource:GetSelectedHeroEntity(playerID)
        end
      end

      if not self:IsActive() then
        return
      end

      local player = self:PlayerForDuel(playerID)
      if not player or not player.assigned or not player.duelNumber then
        -- player is not in a duel, they can just chill tf out
        return
      end
      if player.killed or not player.disconnected then
        return
      end
      player.disconnected = false
      hero:RemoveModifierByName("modifier_out_of_duel")

      self:UnCountPlayerDeath(player)
    end
  end)

  GameEvents:OnPlayerDisconnect(function(keys)
-- [VScript] [components\duels\duels:48] PlayerID: 1
-- [VScript] [components\duels\duels:48] splitscreenplayer: -1
    local playerID = keys.PlayerID
    if playerID then
      local hero = PlayerResource:GetSelectedHeroEntity(playerID)
      if hero then
        hero:Stop()
        hero:AddNewModifier(nil, nil, "modifier_out_of_duel", nil)
      end

      if not self:IsActive() then
        return
      end

      local player = self:PlayerForDuel(playerID)
      if not player or not player.assigned or not player.duelNumber then
        -- player is not in a duel, they can just chill tf out
        return
      end
      player.disconnected = true
      if player.killed then
        return
      end

      self:CountPlayerDeath(player)
    end
  end)

  Timers:CreateTimer(INITIAL_DUEL_DELAY, function ()
    self:StartDuel({
      players = 0,
      firstDuel = true,
      timeout = FIRST_DUEL_TIMEOUT
    })
  end)

  -- Add chat commands to force start and end duels
  ChatCommand:LinkCommand("-duel", Dynamic_Wrap(self, "StartDuel"), self)
  ChatCommand:LinkCommand("-end_duel", Dynamic_Wrap(self, "EndDuel"), self)
end

function Duels:RegisterZone(zoneName)
  self.zones = self.zones or {}
  table.insert(
    self.zones,
    ZoneControl:CreateZone(zoneName, {
      mode = ZONE_CONTROL_INCLUSIVE,
      margin = 500,
      padding = 200,
      players = {}
      })
  )
end

function Duels:CountPlayerDeath (player)
  local scoreIndex = player.team .. 'Living' .. player.duelNumber
  self.currentDuel[scoreIndex] = self.currentDuel[scoreIndex] - 1

  if self.currentDuel[scoreIndex] <= 0 then
    self.currentDuel['duelEnd' .. player.duelNumber] = player.team
    DebugPrint('Duel number ' .. scoreIndex .. ' is over and ' .. player.team .. ' lost')
    local winningTeam = "bad"
    if player.team == "bad" then
      winningTeam = "good"
    end

    self:AllPlayers(self.currentDuel, function (otherPlayer)
      if player.duelNumber ~= otherPlayer.duelNumber then
        return
      end
      Notifications:Top(otherPlayer.id, {
        text = "#DOTA_Winner_" .. winningTeam .. "Guys",
        duration = 5.0,
        style = {
          color = "red",
          ["font-size"] = "110px"
        }
      })
    end)


  end

  if self.currentDuel.duelEnd1 and self.currentDuel.duelEnd2 then
    DebugPrint('both duels are over, resuming normal play!')
    self:EndDuel()
  end
end

function Duels:UnCountPlayerDeath (player)
  local scoreIndex = player.team .. 'Living' .. player.duelNumber
  self.currentDuel[scoreIndex] = self.currentDuel[scoreIndex] + 1
end

function Duels:IsActive ()
  if not self.currentDuel or self.currentDuel == DUEL_IS_STARTING then
    return false
  end
  return true
end

function Duels:CheckDuelStatus (hero)
  if not self:IsActive() then
    return
  end
  if hero:IsReincarnating() then
    hero:SetRespawnsDisabled(false)
    Timers:CreateTimer(1, function ()
      hero:SetRespawnsDisabled(true)
    end )
    return
  end

  local playerId = hero:GetPlayerOwnerID()

  local player = self:PlayerForDuel(playerId)
  if not player then
    -- player is not in this duel!
    return
  end

  if not player.assigned or not player.duelNumber then
    DebugPrint('Player died who isnt in a duel?')
    DebugPrintTable(self.currentDuel)
    DebugPrintTable(player)
    return
  end

  if player.killed then
    -- this player is already dead and shouldn't be counted again
    -- this shouldn't happen, but is nice to have here for future use cases of this method
    DebugPrint('Player died twice in duel?')
    DebugPrintTable(self.currentDuel)
    DebugPrintTable(player)
    return
  end

  if not player.disconnected then
    player.killed = true
  end

  self:CountPlayerDeath(player)
end

function Duels:StartDuel(options)
  if self.currentDuel then
    DebugPrint ('There is already a duel running')
    return
  end
  options = options or {}
  if not options.firstDuel then
    Music:SetMusic(12)
  end
  Timers:RemoveTimer('EndDuel')
  self.currentDuel = DUEL_IS_STARTING
  DuelPreparingEvent.broadcast(true)

  Notifications:TopToAll({text="#duel_imminent_warning", duration=math.min(DUEL_START_WARN_TIME, 5.0), replacement_map={seconds_to_duel = DUEL_START_WARN_TIME}})
  for index = 0,(DUEL_START_COUNTDOWN - 1) do
    Timers:CreateTimer(DUEL_START_WARN_TIME - DUEL_START_COUNTDOWN + index, function ()
      Notifications:TopToAll({text=(DUEL_START_COUNTDOWN - index), duration=1.0})
    end)
  end

  Timers:CreateTimer(DUEL_START_WARN_TIME, function ()
    Notifications:TopToAll({text="#duel_start", duration=3.0, style={color="red", ["font-size"]="110px"}})
    for _, zone in ipairs(self.zones) do
      ZoneCleaner:CleanZone(zone)
    end
    self:ActuallyStartDuel(options)
  end)
end

function Duels:ActuallyStartDuel(options)
  -- respawn everyone
  local goodPlayerIndex = 1
  local badPlayerIndex = 1
  local validGoodPlayerIndex = 1
  local validBadPlayerIndex = 1

  local goodPlayers = {}
  local badPlayers = {}

  for playerId = 0,19 do
    local player = PlayerResource:GetPlayer(playerId)
    if player ~= nil then
      if player:GetAssignedHero() then
        if player:GetTeam() == DOTA_TEAM_BADGUYS then
          badPlayers[badPlayerIndex] = HeroState.SaveState(player:GetAssignedHero())
          badPlayers[badPlayerIndex].id = playerId
          -- used to generate keynames like badEnd1
          -- not used in dota apis
          badPlayers[badPlayerIndex].team = 'bad'
          badPlayerIndex = badPlayerIndex + 1
          validBadPlayerIndex = validBadPlayerIndex + 1

        elseif player:GetTeam() == DOTA_TEAM_GOODGUYS then
          goodPlayers[goodPlayerIndex] = HeroState.SaveState(player:GetAssignedHero())
          goodPlayers[goodPlayerIndex].id = playerId
          goodPlayers[goodPlayerIndex].team = 'good'
          goodPlayerIndex = goodPlayerIndex + 1
          validGoodPlayerIndex = validGoodPlayerIndex + 1
        end

        HeroState.ResetState(player:GetAssignedHero())
      end
    else
      local hero = PlayerResource:GetSelectedHeroEntity(playerId)
      local function CreateDisonnectedPlayer ()
        return {
          assignable = false
        }
      end
      if hero ~= nil then
        if PlayerResource:GetTeam(playerId) == DOTA_TEAM_BADGUYS then
          badPlayers[badPlayerIndex] = CreateDisonnectedPlayer()
          badPlayers[badPlayerIndex].id = playerId
          badPlayers[badPlayerIndex].team = 'bad'
          badPlayerIndex = badPlayerIndex + 1
        elseif PlayerResource:GetTeam(playerId) == DOTA_TEAM_GOODGUYS then
          goodPlayers[goodPlayerIndex] = CreateDisonnectedPlayer()
          goodPlayers[goodPlayerIndex].id = playerId
          goodPlayers[goodPlayerIndex].team = 'good'
          goodPlayerIndex = goodPlayerIndex + 1
        end
      end
    end
  end

  goodPlayerIndex = goodPlayerIndex - 1
  badPlayerIndex = badPlayerIndex - 1
  validGoodPlayerIndex = validGoodPlayerIndex - 1
  validBadPlayerIndex = validBadPlayerIndex - 1

  -- split up players, put them in the duels
  local maxPlayers = math.min(validGoodPlayerIndex, validBadPlayerIndex)

  DebugPrint('Max players per team for this duel ' .. maxPlayers)

  if maxPlayers < 1 then
    DebugPrint('There aren\'t enough players to start the duel')
    Notifications:TopToAll({text="#duel_not_enough_players", duration=2.0})
    self.currentDuel = nil
    Music:PlayBackground(1, 7)
    return
  end

  Music:SetMusic(13)

  local playerSplitOffset = RandomInt(0, maxPlayers)
  if options.players then
    playerSplitOffset = math.min(options.players, maxPlayers)
  end
  -- local playerSplitOffset = maxPlayers
  local spawnLocations = RandomInt(0, 1) == 1
  local arenaChoice = RandomInt(0, 1) == 1
  local duel_1 = 'duel_1'
  local duel_2 = 'duel_2'
  if arenaChoice then
    duel_1 = 'duel_3'
  end
  local spawn1 = Entities:FindByName(nil, duel_1 .. '_spawn_1'):GetAbsOrigin()
  local spawn2 = Entities:FindByName(nil, duel_1 .. '_spawn_2'):GetAbsOrigin()

  if spawnLocations then
    local tmp = spawn1
    spawn1 = spawn2
    spawn2 = tmp
  end

  for playerNumber = 1,playerSplitOffset do
    DebugPrint('Adding player number ' .. playerNumber)
    local goodGuy = self:GetUnassignedPlayer(goodPlayers, goodPlayerIndex)
    local badGuy = self:GetUnassignedPlayer(badPlayers, badPlayerIndex)
    local goodPlayer = PlayerResource:GetPlayer(goodGuy.id)
    local badPlayer = PlayerResource:GetPlayer(badGuy.id)
    local goodHero = goodPlayer:GetAssignedHero()
    local badHero = badPlayer:GetAssignedHero()

    goodGuy.duelNumber = 1
    badGuy.duelNumber = 1

    SafeTeleportAll(goodHero, spawn1, 150)
    SafeTeleportAll(badHero, spawn2, 150)

    if arenaChoice then
      self.zones[3].addPlayer(goodGuy.id)
      self.zones[3].addPlayer(badGuy.id)
    else
      self.zones[1].addPlayer(goodGuy.id)
      self.zones[1].addPlayer(badGuy.id)
    end

    MoveCameraToPlayer(goodHero)
    MoveCameraToPlayer(badHero)

    -- stop player action
    goodHero:Stop()
    badHero:Stop()

    -- disable respawn
    goodHero:SetRespawnsDisabled(true)
    badHero:SetRespawnsDisabled(true)
  end

  spawnLocations = RandomInt(0, 1) == 1
  arenaChoice = RandomInt(0, 1) == 1
  if arenaChoice then
    duel_2 = 'duel_4'
  end

  spawn1 = Entities:FindByName(nil, duel_2 .. '_spawn_1'):GetAbsOrigin()
  spawn2 = Entities:FindByName(nil, duel_2 .. '_spawn_2'):GetAbsOrigin()

  if spawnLocations then
    local tmp = spawn1
    spawn1 = spawn2
    spawn2 = tmp
  end

  for playerNumber = playerSplitOffset+1,maxPlayers do
    DebugPrint('Adding player number ' .. playerNumber)
    local goodGuy = self:GetUnassignedPlayer(goodPlayers, goodPlayerIndex)
    local badGuy = self:GetUnassignedPlayer(badPlayers, badPlayerIndex)
    local goodPlayer = PlayerResource:GetPlayer(goodGuy.id)
    local badPlayer = PlayerResource:GetPlayer(badGuy.id)
    local goodHero = goodPlayer:GetAssignedHero()
    local badHero = badPlayer:GetAssignedHero()

    goodGuy.duelNumber = 2
    badGuy.duelNumber = 2

    SafeTeleportAll(goodHero, spawn1, 150)
    SafeTeleportAll(badHero, spawn2, 150)

    if arenaChoice then
      self.zones[4].addPlayer(goodGuy.id)
      self.zones[4].addPlayer(badGuy.id)
    else
      self.zones[2].addPlayer(goodGuy.id)
      self.zones[2].addPlayer(badGuy.id)
    end

    MoveCameraToPlayer(goodHero)
    MoveCameraToPlayer(badHero)

    -- stop player action
    goodHero:Stop()
    badHero:Stop()

    -- disable respawn
    goodHero:SetRespawnsDisabled(true)
    badHero:SetRespawnsDisabled(true)
  end

  for _,player in ipairs(badPlayers) do
    if player.assigned == nil then
      local hero = PlayerResource:GetSelectedHeroEntity(player.id)
      hero:Stop()
      hero:AddNewModifier(nil, nil, "modifier_out_of_duel", nil)
    end
  end
  for _,player in ipairs(goodPlayers) do
    if player.assigned == nil then
      local hero = PlayerResource:GetSelectedHeroEntity(player.id)
      hero:Stop()
      hero:AddNewModifier(nil, nil, "modifier_out_of_duel", nil)
    end
  end

  self.currentDuel = {
    goodLiving1 = playerSplitOffset,
    badLiving1 = playerSplitOffset,
    goodLiving2 = maxPlayers - playerSplitOffset,
    badLiving2 = maxPlayers - playerSplitOffset,
    duelEnd1 = playerSplitOffset == 0,
    duelEnd2 = maxPlayers == playerSplitOffset,
    badPlayers = badPlayers,
    goodPlayers = goodPlayers,
    badPlayerIndex = badPlayerIndex,
    goodPlayerIndex = goodPlayerIndex
  }
  DuelStartEvent.broadcast(self.currentDuel)

  if options.timeout == nil then
    options.timeout = DUEL_TIMEOUT
  end

  if options.timeout ~= 0 then
    Timers:CreateTimer('EndDuel', {
      endTime = options.timeout,
      callback = function()
        self:TimeoutDuel()
      end
    })
  end
end

function Duels:GetUnassignedPlayer (group, max)
  while true do
    local playerIndex = RandomInt(1, max)
    if group[playerIndex].assignable and group[playerIndex].assigned == nil then
      group[playerIndex].assigned = true
      return group[playerIndex]
    end
  end
end

function Duels:TimeoutDuel ()
  if self.currentDuel == nil then
    DebugPrint ('There is no duel running')
    return
  end

  DebugPrint('timing out the duel because this isnt going well...')
  Timers:RemoveTimer('EndDuel')

  for i = 0,(DUEL_END_COUNTDOWN - 1) do
    Timers:CreateTimer(i, function ()
      if self.currentDuel == nil then
        return
      end
      Notifications:TopToAll({text=tostring(DUEL_END_COUNTDOWN - i), duration=1.0})
    end)
  end

  Timers:CreateTimer('EndDuel', {
    endTime = DUEL_END_COUNTDOWN,
    callback = function()
      self:EndDuel()
    end
  })
end

function Duels:EndDuel ()
  if self.currentDuel == nil then
    DebugPrint ('There is no duel running')
    return
  end

  DebugPrint('Duel has ended')
  Timers:RemoveTimer('EndDuel')

  Music:PlayBackground(1, 7)

  local nextDuelIn = DUEL_INTERVAL

  if self.startDuelTimer then
    Timers:RemoveTimer(self.startDuelTimer)
    self.startDuelTimer = nil
  end

  self.startDuelTimer = Timers:CreateTimer(nextDuelIn - 60 + DUEL_START_WARN_TIME, function ()
    Notifications:TopToAll({text="#duel_minute_warning", duration=10.0})
    self.startDuelTimer = Timers:CreateTimer(60 - DUEL_START_WARN_TIME, partial(self.StartDuel, self))
  end)

  for playerId = 0,19 do
    for _, zone in ipairs(self.zones) do
      zone.removePlayer(playerId, false)
    end
  end

  local currentDuel = self.currentDuel
  self.currentDuel = nil

  Timers:CreateTimer(0.1, function ()
    DebugPrint('Sending all players back!')
    self:AllPlayers(currentDuel, function (state)
      local player = PlayerResource:GetPlayer(state.id)
      if player == nil then -- disconnected!
        return
      end

      local hero = player:GetAssignedHero()
      if not hero:IsAlive() then
        hero:SetRespawnsDisabled(false)
        hero:RespawnHero(false,false)
        -- hero is changed on respawn sometimes
        hero = player:GetAssignedHero()
      else
        hero:RemoveModifierByName("modifier_out_of_duel")
      end

      if not state.assigned then
        return
      end

      HeroState.RestoreState(hero, state)
      MoveCameraToPlayer(hero)
      HeroState.PurgeDuelHighgroundBuffs(hero)
    end)
    -- Remove Modifier
    for playerId = 0,19 do
      local player = PlayerResource:GetPlayer(playerId)
      if player then
        local hero = PlayerResource:GetSelectedHeroEntity(playerId)

        if hero ~= nil then
          hero:RemoveModifierByName("modifier_out_of_duel")
        end
      end
    end
    DuelEndEvent.broadcast(currentDuel)
  end)
end

function Duels:AllPlayers(state, cb)
  if state == nil then
    for playerId = 0,19 do
      local player = PlayerResource:GetPlayer(playerId)
      if player ~= nil then
        cb(player)
      end
    end
  else
    for playerIndex = 1,state.badPlayerIndex do
      if state.badPlayers[playerIndex] ~= nil then
        cb(state.badPlayers[playerIndex])
      end
    end
    for playerIndex = 1,state.goodPlayerIndex do
      if state.goodPlayers[playerIndex] ~= nil then
        cb(state.goodPlayers[playerIndex])
      end
    end
  end
end

function Duels:PlayerForDuel(playerId)
  local foundIt = false

  Duels:AllPlayers(Duels.currentDuel, function (player)
    if foundIt or player.id ~= playerId then
      return
    end
    foundIt = player
  end)

  return foundIt
end

