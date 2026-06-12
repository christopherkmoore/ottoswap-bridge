-- ottoswap-bridge: a thin Windower connector for ottoswap (https://ottoswap.ckmtools.dev).
--
-- It reads your GearSwap sets (the whole addons/GearSwap/data tree) plus your live equipped
-- gear and the items you own, and POSTs them to the ottoswap relay over HTTPS, keyed by a
-- pairing code from the website. All analysis runs in your browser; this addon is just the pipe.
--
-- SAFETY: this addon only SENDS data OUT. There is deliberately no inbound command channel —
-- it cannot receive or run any command on your client. It's open source so you can verify that.
--
-- Setup:  put this `ottoswap-bridge` folder in Windower/addons, then in game:
--   //lua load ottoswap-bridge
--   //ottoswap setup <pairing-code>      (the code is shown on the website)

_addon.name = 'ottoswap-bridge'
_addon.version = '0.2.0'
_addon.author = 'ckm'
_addon.commands = {'ottoswap'}

local https = require('ssl.https')
local ltn12 = require('ltn12')
local extdata = require('extdata')
local config = require('config')

local defaults = {
    endpoint = 'https://ottoswapapi.ckmtools.dev',
    token = '',
    push_interval = 5,    -- min seconds between live snapshots
    sets_interval = 120,  -- min seconds between re-scans of the GearSwap data tree
}
local settings = config.load(defaults)

local state = {
    last_live_check = 0, last_sets_check = 0,
    last_live = nil, last_sets = nil, last_stats_data = nil,
}

local function log(msg) windower.add_to_chat(6, '[ottoswap] ' .. msg) end

-- JSON string with full escaping (handles newlines/quotes/control chars in Lua file text)
local function json_string(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local e = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
                    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
        return e[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

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

-- ---------------------------------------------------------------------------
-- HTTPS transport. LuaSec's request is blocking, so we push on change + throttle.
-- ---------------------------------------------------------------------------
local function http_post(path, body)
    local resp = {}
    local ok, code = https.request{
        url = settings.endpoint .. path,
        method = 'POST',
        headers = { ['Content-Type'] = 'application/json', ['Content-Length'] = tostring(#body) },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp),
    }
    return ok, code
end

-- ---------------------------------------------------------------------------
-- Sets channel: read the entire GearSwap/data tree and push raw file text.
-- ---------------------------------------------------------------------------
local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local c = f:read('*a'); f:close()
    return c
end

-- recurse the data dir, collecting every .lua file as relpath -> raw text
local function collect_sets(dir, prefix, out, depth)
    if depth > 6 then return end
    for _, name in ipairs(windower.get_dir(dir) or {}) do
        local full = dir .. name
        if windower.dir_exists(full) then
            collect_sets(full .. '/', prefix .. name .. '/', out, depth + 1)
        elseif name:sub(-4):lower() == '.lua' then
            local content = read_file(full)
            if content then out[prefix .. name] = content end
        end
    end
end

local function build_sets_json()
    local sets = {}
    collect_sets(windower.windower_path .. 'addons/GearSwap/data/', '', sets, 0)
    local parts = {}
    for relpath, content in pairs(sets) do
        parts[#parts + 1] = json_string(relpath) .. ':' .. json_string(content)
    end
    if #parts == 0 then return nil end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function push_sets(force)
    if settings.token == '' then return end
    local body = build_sets_json()
    if not body then return end
    if not force and body == state.last_sets then return end
    local ok, code = http_post('/sets/' .. settings.token, body)
    if ok and (code == 200 or code == 204) then state.last_sets = body
    elseif force then log('sets push failed (' .. tostring(code) .. ')') end
end

-- ---------------------------------------------------------------------------
-- Live channel: equipped gear + equippable bags + base stats/skills.
-- ---------------------------------------------------------------------------
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
                parts[#parts + 1] = json_string(augment)
            end
        end
    end
    if #parts == 0 then return nil end
    return '[' .. table.concat(parts, ',') .. ']'
end

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

local function u16(data, off) return data:byte(off + 1) + data:byte(off + 2) * 256 end
local function u32(data, off)
    return data:byte(off + 1) + data:byte(off + 2) * 256 + data:byte(off + 3) * 65536 + data:byte(off + 4) * 16777216
end
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
    if not data or #data < 0x22 then return '"stats":null,"skills":' .. skills end
    local s = string.format(
        '{"str":%d,"dex":%d,"vit":%d,"agi":%d,"int":%d,"mnd":%d,"chr":%d,"maxhp":%d,"maxmp":%d,"mainjob":"%s","mainlvl":%d}',
        u16(data, 0x14), u16(data, 0x16), u16(data, 0x18), u16(data, 0x1A),
        u16(data, 0x1C), u16(data, 0x1E), u16(data, 0x20),
        u32(data, 0x04), u32(data, 0x08),
        (player and player.main_job) or '?', (player and player.main_job_level) or 0)
    return '"stats":' .. s .. ',"skills":' .. skills
end

local function build_live()
    local player = windower.ffxi.get_player()
    if not player then return nil end
    local gear = gear_json()
    if not gear then return nil end
    return '{"char":' .. json_string(player.name) .. ',' .. gear .. ',' .. stats_json() .. '}'
end

local function push_live(force)
    if settings.token == '' then return end
    local body = build_live()
    if not body then return end
    if not force and body == state.last_live then return end
    local ok, code = http_post('/push/' .. settings.token, body)
    if ok and (code == 200 or code == 204) then state.last_live = body
    elseif force then log('live push failed (' .. tostring(code) .. ')') end
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
    if now - state.last_live_check >= settings.push_interval then
        state.last_live_check = now
        push_live(false)
    end
    if now - state.last_sets_check >= settings.sets_interval then
        state.last_sets_check = now
        push_sets(false)
    end
end)

windower.register_event('addon command', function(command, ...)
    local args = {...}
    command = command and command:lower() or 'status'
    if command == 'setup' or command == 'pair' then
        if args[1] then
            settings.token = args[1]
            settings:save()
            log('paired. sending your sets + gear to ottoswap.')
            push_sets(true)
            push_live(true)
        else
            log('usage: //ottoswap setup <pairing-code>')
        end
    elseif command == 'endpoint' then
        if args[1] then settings.endpoint = args[1]; settings:save(); log('endpoint set to ' .. settings.endpoint) end
    elseif command == 'push' then
        push_sets(true); push_live(true); log('pushed.')
    elseif command == 'status' then
        log(settings.token ~= '' and ('paired -> ' .. settings.endpoint) or 'not paired')
    else
        log('commands: setup <code> | push | status | endpoint <url>')
    end
end)
