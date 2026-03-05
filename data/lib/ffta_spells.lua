-- FFTA Spell Learning System
-- Inspired by Final Fantasy Tactics Advanced.
-- Spells are learned temporarily while an item is equipped.
-- They become PERMANENT after accumulating the required kills with that item equipped.
-- Kills do NOT need to be the final hit.
-- Each vocation can learn a different spell from the same item.
--
-- CONFIGURATION:
--   FftaSpells.config[itemId][vocationId] = {
--       spell        = "spell name",   -- exact name registered in spells.xml
--       killsRequired = 50,            -- number of kills needed to learn permanently
--       creatures    = nil,            -- nil = any creature; or a table like {"rat","wolf"}
--   }
--
-- To add more items/spells, just extend FftaSpells.config below.

FftaSpells = {}

---------------------------------------------------------------------------
-- Storage key namespace for "this spell is temporarily equipped"
-- We use player storage to track which spells were granted temporarily
-- so we do NOT call forgetSpell on permanently learned ones.
-- Keys: FFTA_TEMP_SPELL_BASE + crc32-like hash of the spell name (mod 100000)
---------------------------------------------------------------------------
local FFTA_TEMP_BASE = 90000000  -- storage key prefix for temporary spell flags

---------------------------------------------------------------------------
-- CONFIG TABLE
-- itemId => { [vocationId] = { spell, killsRequired, creatures } }
-- Vocation IDs (default TFS): 1=Sorcerer,2=Druid,3=Paladin,4=Knight,
--                             5=Master Sorcerer,6=Elder Druid,7=Royal Paladin,8=Elite Knight
--                             0 = no vocation (used as fallback / "any")
-- Use vocationId 0 as a catch-all if all vocations learn the same spell.
---------------------------------------------------------------------------
FftaSpells.config = {
    -- Example: Long Sword (item id 2400)
    [2400] = {
        [4] = { spell = "exori",      killsRequired = 50,  creatures = nil },
        [8] = { spell = "exori gran", killsRequired = 100, creatures = nil },
    },
    -- Example: Dagger (item id 2389) — only Sorcerer and Master Sorcerer
    [2389] = {
        [1] = { spell = "exura",      killsRequired = 30,  creatures = {"rat", "cave rat"} },
        [5] = { spell = "exura gran", killsRequired = 60,  creatures = {"rat", "cave rat"} },
    },
    -- Example: helmet/armor: any slot works, just list the item id
    -- [item_id] = {
    --   [voc_id] = { spell = "...", killsRequired = N, creatures = nil },
    -- },
}

---------------------------------------------------------------------------
-- INTERNAL HELPERS
---------------------------------------------------------------------------

-- Simple string hash to get a deterministic storage offset per spell name.
-- Keeps keys in the 0–99999 range added to FFTA_TEMP_BASE.
local function spellHash(name)
    local h = 0
    for i = 1, #name do
        h = (h * 31 + string.byte(name, i)) % 100000
    end
    return h
end

local function tempStorageKey(spellName)
    return FFTA_TEMP_BASE + spellHash(spellName)
end

-- Returns the entry { spell, killsRequired, creatures } or nil
function FftaSpells.getConfig(itemId, vocationId)
    local itemCfg = FftaSpells.config[itemId]
    if not itemCfg then return nil end
    -- exact vocation match
    local entry = itemCfg[vocationId]
    if entry then return entry end
    -- fallback: any-vocation (key 0)
    return itemCfg[0]
end

-- Returns true if the creature name matches the allowed list (or if the list is nil).
local function creatureMatches(creatureList, creatureName)
    if not creatureList then return true end
    local lname = creatureName:lower()
    for _, c in ipairs(creatureList) do
        if c:lower() == lname then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- DB HELPERS
---------------------------------------------------------------------------

function FftaSpells.getKills(playerId, itemId, creature)
    creature = creature or ""
    local resultId = db.storeQuery(string.format(
        "SELECT `kills` FROM `player_equipment_ab_kills` WHERE `player_id` = %d AND `item_id` = %d AND `creature` = %s",
        playerId, itemId, db.escapeString(creature)
    ))
    if not resultId then return 0 end
    local kills = result.getNumber(resultId, "kills")
    result.free(resultId)
    return kills
end

function FftaSpells.addKill(playerId, itemId, creature)
    creature = creature or ""
    db.asyncQuery(string.format(
        "INSERT INTO `player_equipment_ab_kills` (`player_id`, `item_id`, `creature`, `kills`) VALUES (%d, %d, %s, 1) " ..
        "ON DUPLICATE KEY UPDATE `kills` = `kills` + 1",
        playerId, itemId, db.escapeString(creature)
    ))
end

---------------------------------------------------------------------------
-- TEMPORARY / PERMANENT LEARN LOGIC
---------------------------------------------------------------------------

-- Mark a spell as "temporarily learned" via storage (so we know to forget it on unequip)
local function markTemporary(player, spellName)
    player:setStorageValue(tempStorageKey(spellName), 1)
end

-- Clear the temporary mark (spell is now permanent or being forgotten)
local function clearTemporary(player, spellName)
    player:setStorageValue(tempStorageKey(spellName), -1)
end

local function isTemporary(player, spellName)
    return player:getStorageValue(tempStorageKey(spellName)) == 1
end

-- Grant a spell temporarily (equip)
local function grantTemporary(player, spellName)
    if not player:hasLearnedSpell(spellName) then
        player:learnSpell(spellName)
        markTemporary(player, spellName)
        player:sendTextMessage(MESSAGE_STATUS_CONSOLE_ORANGE,
            string.format("Você tem acesso à magia '%s' enquanto este equipamento estiver equipado.", spellName))
    end
end

-- Revoke a temporarily-learned spell (unequip)
local function revokeTemporary(player, spellName)
    if isTemporary(player, spellName) then
        player:forgetSpell(spellName)
        clearTemporary(player, spellName)
        player:sendTextMessage(MESSAGE_STATUS_CONSOLE_ORANGE,
            string.format("Você perdeu o acesso temporário à magia '%s'.", spellName))
    end
end

-- Permanently learn a spell (threshold reached)
local function learnPermanent(player, spellName)
    if isTemporary(player, spellName) then
        -- Already granted temporarily — just promote it to permanent
        clearTemporary(player, spellName)
    else
        player:learnSpell(spellName)
    end
    player:sendTextMessage(MESSAGE_EVENT_ADVANCE,
        string.format("Você aprendeu permanentemente a magia '%s'!", spellName))
end

---------------------------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------------------------

-- Called when a player equips an item.
function FftaSpells.onEquip(player, item)
    local itemId  = item:getId()
    local vocId   = player:getVocationId()
    local entry   = FftaSpells.getConfig(itemId, vocId)
    if not entry then return end

    local spellName = entry.spell
    -- If already permanently learned, nothing to do
    if player:hasLearnedSpell(spellName) and not isTemporary(player, spellName) then
        return
    end
    grantTemporary(player, spellName)
end

-- Called when a player unequips an item.
function FftaSpells.onUnequip(player, item)
    local itemId  = item:getId()
    local vocId   = player:getVocationId()
    local entry   = FftaSpells.getConfig(itemId, vocId)
    if not entry then return end

    -- Only revoke if not yet permanently learned
    revokeTemporary(player, entry.spell)
end

-- Called from onKill (creature script). target is the creature that died.
function FftaSpells.onKill(player, target)
    if not target or not target:isMonster() then return end
    local creatureName = target:getName()
    local vocId        = player:getVocationId()
    local playerId     = player:getId()

    -- Check every equipped item slot for matching config
    local slots = {
        CONST_SLOT_HEAD, CONST_SLOT_NECKLACE, CONST_SLOT_BACKPACK,
        CONST_SLOT_ARMOR, CONST_SLOT_RIGHT, CONST_SLOT_LEFT,
        CONST_SLOT_LEGS, CONST_SLOT_FEET, CONST_SLOT_RING, CONST_SLOT_AMMO
    }

    for _, slot in ipairs(slots) do
        local item = player:getSlotItem(slot)
        if item then
            local itemId = item:getId()
            local entry  = FftaSpells.getConfig(itemId, vocId)
            if entry and creatureMatches(entry.creatures, creatureName) then
                -- Record the kill (use empty string as creature key = "any" mode,
                -- or creatureName if creatures list was specified)
                local creatureKey = entry.creatures and creatureName or ""
                FftaSpells.addKill(playerId, itemId, creatureKey)

                -- Check if threshold has been reached (we read kills + 1 optimistically)
                local kills = FftaSpells.getKills(playerId, itemId, creatureKey) + 1
                if kills >= entry.killsRequired and not (player:hasLearnedSpell(entry.spell) and not isTemporary(player, entry.spell)) then
                    learnPermanent(player, entry.spell)
                end
            end
        end
    end
end

-- Called on player login: re-apply temporary spells for currently equipped items.
function FftaSpells.restoreLearnedSpells(player)
    local vocId = player:getVocationId()
    local slots = {
        CONST_SLOT_HEAD, CONST_SLOT_NECKLACE, CONST_SLOT_BACKPACK,
        CONST_SLOT_ARMOR, CONST_SLOT_RIGHT, CONST_SLOT_LEFT,
        CONST_SLOT_LEGS, CONST_SLOT_FEET, CONST_SLOT_RING, CONST_SLOT_AMMO
    }
    for _, slot in ipairs(slots) do
        local item = player:getSlotItem(slot)
        if item then
            local entry = FftaSpells.getConfig(item:getId(), vocId)
            if entry then
                local spellName = entry.spell
                -- Only grant temporary if not already permanently learned
                if not player:hasLearnedSpell(spellName) then
                    grantTemporary(player, spellName)
                end
            end
        end
    end
end

print("[FFTA] ffta_spells.lua carregado.")
