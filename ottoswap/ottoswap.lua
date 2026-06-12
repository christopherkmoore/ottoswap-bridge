-- ottoswap-bridge: a thin Windower connector for ottoswap (https://ottoswap.ckmtools.dev).
--
-- It reads your live equipped gear + the equippable items you own and POSTs them to the
-- ottoswap relay over HTTPS, keyed by a pairing code you get from the website. The website
-- (which runs all the analysis in your browser) then shows and analyzes your sets.
--
-- SAFETY: this addon only SENDS data OUT. It never receives or executes any command — there
-- is deliberately no inbound command channel. It's open source so you can verify that.
--
-- Setup:  drop this `ottoswap` folder into Windower/addons, then in game:
--   //lua load ottoswap
--   //ottoswap setup <pairing-code>      (the code is shown on the website)

_addon.name = 'ottoswap'
_addon.version = '0.1.0'
_addon.author = 'ckm'
_addon.commands = {'ottoswap'}

local https = require('ssl.https')
local ltn12 = require('ltn12')
local extdata = require('extdata')
local config = require('config')

local defaults = {
    endpoint = 'https://ottoswapapi.ckmtools.dev',
    token = '',
    push_interval = 5,  -- min seconds between live snapshots
}
local settings = config.load(defaults)

local state = { last_check = 0, last_snapshot = nil, last_stats_data = nil }

local function log(msg) windower.add_to_chat(6, '[ottoswap] ' .. msg) end

-- windower bag ids a character can equip from
local gear_bags = {
    inventory = 0,
    wardrobe = 8, wardrobe2 = 10, wardrobe3 = 11, wardrobe4 = 12,
    wardrobe5 = 13, wardrobe6 = 14, wardrobe7 = 15, wardrobe8 = 16,
}
-- windower equipment key -> the slot name the web client uses
local equipment_slots = {
    main = 'main', sub = 'sub', range = 'range', ammo = 'ammo',
    head = 'head', neck = 'neck', left_ear = 'ear1', right_ear = 'ear2',
    body = 'body', hands = 'hands', left_ring = 'ring1', right_ring = 'ring2',
    back = 'back', waist = 'waist', legs = 'legs', feet = 'feet',
}

local function json_escape(text)
    return tostring(text):gsub('\\', '\\\\'):gsub('"', '\\"')
end

-- ---------------------------------------------------------------------------
-- Readers (what you own / have equipped / your base stats + skills)
-- ---------------------------------------------------------------------------

-- Decode an item's extdata to a JSON augments array, or nil. Path/RP gear (system 4,
-- Sortie/Odyssey) is forwarded as a raw `xd:` hex token for the web client to decode.
local function item_augments_json(item)
    if not item.extdata then return nil end
    local ok, decoded = pcall(extdata.decode, item)
    if not ok or not decoded then return nil end
    if decoded.augment_system == 4 then
        local hex = {}
        for n = 1, #item.extdata do hex[n] = string.format('%02X', item.extdata:byte(n)) end
        return '["xd:' .. table.concat(hex) .. '"]'
    end
    local parts = {}
    if decoded.augments then
        for _, augment in ipairs(decoded.augments) do
            if augment and augment ~= 'none' and augment ~= '' then
                parts[#parts + 1] = '"' .. json_escape(augment) .. '"'
            end
        end
    end
    if #parts == 0 then return nil end
    return '[' .. table.concat(parts, ',') .. ']'
end

-- equipment: slot -> {id, augments?}  /  bags: name -> [[id,count,(augments)], ...]
local function gear_json()
    local all = windower.ffxi.get_items()
    if not all or not all.equipment then return nil end

    local equip_parts = {}
    for windower_key, slot_name in pairs(equipment_slots) do
        local index = all.equipment[windower_key]
        local bag_id = all.equipment[windower_key .. '_bag']
        if index and index > 0 then
            local bag = windower.ffxi.get_items(bag_id)
            local item = bag and bag[index]
            if item and item.id and item.id > 0 then
                local augments = item_augments_json(item)
                equip_parts[#equip_parts + 1] = '"' .. slot_name .. '":{"id":' .. item.id ..
                    (augments and (',"augments":' .. augments) or '') .. '}'
            end
        end
    end

    local bag_parts = {}
    for bag_name, bag_id in pairs(gear_bags) do
        local bag = windower.ffxi.get_items(bag_id)
        if bag and bag.enabled ~= false then
            local item_parts = {}
            for n = 1, (bag.max or 0) do
                local item = bag[n]
                if item and item.id and item.id > 0 then
                    local augments = item_augments_json(item)
                    item_parts[#item_parts + 1] = '[' .. item.id .. ',' .. (item.count or 1) ..
                        (augments and (',' .. augments) or '') .. ']'
                end
            end
            bag_parts[#bag_parts + 1] = '"' .. bag_name .. '":[' .. table.concat(item_parts, ',') .. ']'
        end
    end

    return '"equipment":{' .. table.concat(equip_parts, ',') .. '},' ..
           '"bags":{' .. table.concat(bag_parts, ',') .. '}'
end

-- Base attributes from the 0x061 "Char Stats" packet (gear-independent: race+job+merits+JP).
local function u16(data, off) return data:byte(off + 1) + data:byte(off + 2) * 256 end
local function u32(data, off)
    return data:byte(off + 1) + data:byte(off + 2) * 256 + data:byte(off + 3) * 65536 + data:byte(off + 4) * 16777216
end
-- Combat/magic skills (includes Master Levels/merits/JP) as a JSON object.
local function skills_json()
    local p = windower.ffxi.get_player()
    if not p or not p.skills then return '{}' end
    local parts = {}
    for k, v in pairs(p.skills) do
        if type(v) == 'number' then parts[#parts + 1] = '"' .. tostring(k) .. '":' .. v end
    end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function stats_json()
    local data = state.last_stats_data
    local player = windower.ffxi.get_player()
    local skills = skills_json()
    if not data or #data < 0x22 then
        return '"stats":null,"skills":' .. skills
    end
    local s = string.format(
        '{"str":%d,"dex":%d,"vit":%d,"agi":%d,"int":%d,"mnd":%d,"chr":%d,"maxhp":%d,"maxmp":%d,"mainjob":"%s","mainlvl":%d}',
        u16(data, 0x14), u16(data, 0x16), u16(data, 0x18), u16(data, 0x1A),
        u16(data, 0x1C), u16(data, 0x1E), u16(data, 0x20),
        u32(data, 0x04), u32(data, 0x08),
        (player and player.main_job) or '?', (player and player.main_job_level) or 0)
    return '"stats":' .. s .. ',"skills":' .. skills
end

-- ---------------------------------------------------------------------------
-- Transport: HTTPS POST of one snapshot to the relay, keyed by the pairing token.
-- LuaSec's request is blocking, so we push on change + throttle rather than every frame.
-- TODO: import GearSwap set definitions (read the user's GearSwap data files) — next.
-- ---------------------------------------------------------------------------

local function http_post(path, body)
    local resp = {}
    local ok, code = https.request{
        url = settings.endpoint .. path,
        method = 'POST',
        headers = {
            ['Content-Type'] = 'application/json',
            ['Content-Length'] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp),
    }
    return ok, code
end

local function build_snapshot()
    local player = windower.ffxi.get_player()
    if not player then return nil end
    local gear = gear_json()
    if not gear then return nil end
    return '{"char":"' .. json_escape(player.name) .. '",' ..
           gear .. ',' .. stats_json() .. '}'
end

local function push_snapshot(force)
    if settings.token == '' then
        log('not paired — run //ottoswap setup <code> (get the code from the website)')
        return
    end
    local snapshot = build_snapshot()
    if not snapshot then return end
    if not force and snapshot == state.last_snapshot then return end  -- nothing changed
    local ok, code = http_post('/push/' .. settings.token, snapshot)
    if ok and (code == 200 or code == 204) then
        state.last_snapshot = snapshot
    elseif force then
        log('push failed (' .. tostring(code) .. ')')
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

windower.register_event('incoming chunk', function(id, data)
    if id == 0x061 then state.last_stats_data = data end
end)

windower.register_event('prerender', function()
    if settings.token == '' then return end
    local now = os.clock()
    if now - state.last_check < settings.push_interval then return end
    state.last_check = now
    push_snapshot(false)
end)

windower.register_event('addon command', function(command, ...)
    local args = {...}
    command = command and command:lower() or 'status'
    if command == 'setup' or command == 'pair' then
        if args[1] then
            settings.token = args[1]
            settings:save()
            log('paired. pushing your gear to ottoswap.')
            push_snapshot(true)
        else
            log('usage: //ottoswap setup <pairing-code>')
        end
    elseif command == 'endpoint' then
        if args[1] then settings.endpoint = args[1]; settings:save(); log('endpoint set to ' .. settings.endpoint) end
    elseif command == 'push' then
        push_snapshot(true)
        log('pushed.')
    elseif command == 'status' then
        log(settings.token ~= '' and ('paired -> ' .. settings.endpoint) or 'not paired')
    else
        log('commands: setup <code> | push | status | endpoint <url>')
    end
end)
