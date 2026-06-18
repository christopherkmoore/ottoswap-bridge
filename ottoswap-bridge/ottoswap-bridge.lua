-- ottoswap-bridge: a thin Windower connector for ottoswap (https://ottoswap.ckmtools.dev).
--
-- It reads your GearSwap sets (the whole addons/GearSwap/data tree) plus your live equipped
-- gear and the items you own, and POSTs them to the ottoswap relay over HTTPS, keyed by a
-- pairing code from the website. All analysis runs in your browser; this addon is just the pipe.
--
-- Setup:  put this `ottoswap-bridge` folder in Windower/addons, then in game:
--   //lua load ottoswap-bridge
--   //ottoswap setup <pairing-code>      (the code is shown on the website)
-- The pairing persists across sessions. Forgot your code? `//ottoswap code` prints it (and a
-- link to pair other devices), and it's saved to `your-ottoswap-code.txt` in this folder.

_addon.name = 'ottoswap-bridge'
_addon.version = '0.6.4'
_addon.author = 'ckm'
_addon.commands = {'ottoswap'}

local socket = require('socket')           -- luasocket core: tcp() + high-res gettime()
local ssl = require('ssl')                 -- LuaSec core: ssl.wrap / dohandshake for the non-blocking upload
local extdata = require('extdata')
local config = require('config')
local res = require('resources')
local lfs_ok, lfs = pcall(require, 'lfs')  -- optional: gives file mtime for change-detection; falls back to size

local defaults = {
    endpoint = 'https://ottoswapapi.ckmtools.dev',
    site = 'https://ottoswap.ckmtools.dev',   -- the website (for the pairing link)
    token = '',
    push_interval = 30,    -- seconds between (cheap, local) scans for an inventory/augment change
    sets_interval = 600,   -- seconds between (cheap, stat-only) scans of the GearSwap data tree
}
local settings = config.load(defaults)

local state = {
    last_live_check = 0, last_sets_check = 0,
    last_live_sig = nil, last_stats_data = nil,
}

local function log(msg) windower.add_to_chat(6, '[ottoswap] ' .. msg) end

local function pairing_link() return settings.site .. '/#code/' .. settings.token end

-- Write the pairing code to a plain text file in the addon folder so it's recoverable
-- outside the game (the config also persists it to data/settings.xml, but this is the
-- obvious place to look when you forget your code).
local function write_code_file()
    if settings.token == '' then return end
    local path = windower.windower_path .. 'addons/' .. _addon.name .. '/your-ottoswap-code.txt'
    local f = io.open(path, 'w')
    if not f then return end
    f:write('Your ottoswap pairing code: ' .. settings.token .. '\n\n')
    f:write('Open this link on any device (phone, laptop) to pair it — no IP / same-network needed:\n')
    f:write(pairing_link() .. '\n')
    f:close()
end

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
-- Only equippable items (Armor/Weapon) belong in the gear snapshot. The inventory bag also
-- holds consumables, drops, temp items, crystals and currency that churn constantly during play;
-- if those counted toward the change signature, every loot/use would trigger a network push (and
-- two KV writes), blowing the relay's daily write budget. Filtering to gear keeps the signature
-- stable across normal play while still capturing real gear parked in inventory.
local function is_gear(id)
    local it = res.items[id]
    return it and (it.category == 'Armor' or it.category == 'Weapon')
end

-- windower equipment key -> the slot name the web client uses
local equipment_slots = {
    main = 'main', sub = 'sub', range = 'range', ammo = 'ammo',
    head = 'head', neck = 'neck', left_ear = 'ear1', right_ear = 'ear2',
    body = 'body', hands = 'hands', left_ring = 'ring1', right_ring = 'ring2',
    back = 'back', waist = 'waist', legs = 'legs', feet = 'feet',
}

-- ---------------------------------------------------------------------------
-- HTTPS transport. The upload runs inside a Windower coroutine on a non-blocking socket
-- (settimeout(0)), yielding a frame (coroutine.sleep(YIELD)) between polls — so even a multi-MB
-- push never drops a render frame, and it's far faster than ltn12's tiny default chunking because
-- it sends the whole buffer in big writes. Validated against this LuaJIT/LuaSec build: connect
-- completes as err='already connected'; Cloudflare requires conn:sni(host); negotiates TLSv1.3.
-- Stays Lua 5.1/LuaJIT-safe: never yields across pcall, and never error()s on the hot path (a dead
-- coroutine must not strand an in-flight flag — every failure path returns).
-- ---------------------------------------------------------------------------
local YIELD = 0.02   -- positive sleep between polls so the scheduler renders a frame between them;
                     -- sleep(0) busy-spins and would freeze the client (proven via the probe).

local function parse_endpoint(url)
    local scheme, hostport = tostring(url):match('^(%w+)://([^/]+)')
    if not scheme then return nil end
    local host, port = hostport:match('^([^:]+):?(%d*)$')
    return scheme, host, (tonumber(port) or (scheme == 'https' and 443 or 80))
end

-- Open a non-blocking TLS connection (connect + handshake). Returns the wrapped conn or nil,err.
-- Yields between polls; must run inside coroutine.schedule. Cloudflare requires SNI.
local function tls_dial(host, port, deadline)
    local conn = socket.tcp()
    if not conn then return nil, 'no socket' end
    conn:settimeout(0)
    local ok, err = conn:connect(host, port)
    while not (ok == 1 or err == 'already connected') do
        if socket.gettime() > deadline then conn:close(); return nil, 'connect timeout' end
        coroutine.sleep(YIELD)
        ok, err = conn:connect(host, port)
    end
    conn = ssl.wrap(conn, { mode = 'client', protocol = 'any', verify = 'none', options = 'all' })
    conn:settimeout(0)
    if conn.sni then conn:sni(host) end   -- Cloudflare serves many hosts per IP; handshake fails without SNI
    local handshake_ok, handshake_err = conn:dohandshake()
    while not handshake_ok do
        if not (handshake_err == 'wantread' or handshake_err == 'wantwrite' or handshake_err == 'timeout') then
            conn:close(); return nil, 'tls: ' .. tostring(handshake_err)
        end
        if socket.gettime() > deadline then conn:close(); return nil, 'tls timeout' end
        coroutine.sleep(YIELD)
        handshake_ok, handshake_err = conn:dohandshake()
    end
    return conn
end

-- Send the whole buffer over a non-blocking conn, yielding between partial sends.
local function send_all(conn, request, deadline)
    local sent = 0
    while sent < #request do
        local last_byte, send_err, partial = conn:send(request, sent + 1)
        if last_byte then sent = last_byte
        elseif send_err == 'timeout' or send_err == 'wantwrite' or send_err == 'wantread' then
            sent = partial or sent; coroutine.sleep(YIELD)
        else return nil, 'send: ' .. tostring(send_err) end
        if socket.gettime() > deadline then return nil, 'send timeout' end
    end
    return true
end

-- HTTPS POST. Returns true,code on a parsed HTTP status, or nil,err. Must run inside coroutine.schedule.
local function https_post(host, port, path, body, extra_headers)
    local deadline = socket.gettime() + 30
    local conn, err = tls_dial(host, port, deadline)
    if not conn then return nil, err end
    local request = 'POST ' .. path .. ' HTTP/1.1\r\nHost: ' .. host ..
        '\r\nContent-Type: application/json\r\nContent-Length: ' .. #body ..
        '\r\nUser-Agent: ottoswap-bridge/' .. _addon.version .. '\r\n' .. (extra_headers or '') ..
        'Connection: close\r\n\r\n' .. body
    local ok, serr = send_all(conn, request, deadline)
    if not ok then conn:close(); return nil, serr end
    local response = ''   -- only need the status line; the relay commits the write before it responds
    while not response:find('\r\n', 1, true) do
        local data, recv_err, partial = conn:receive(256)
        if data then response = response .. data
        elseif recv_err == 'closed' then response = response .. (partial or ''); break
        elseif recv_err == 'timeout' or recv_err == 'wantread' or recv_err == 'wantwrite' then
            response = response .. (partial or ''); coroutine.sleep(YIELD)
        else conn:close(); return nil, 'recv: ' .. tostring(recv_err) end
        if socket.gettime() > deadline then conn:close(); return nil, 'recv timeout' end
    end
    conn:close()
    local code = tonumber(response:match('HTTP/[%d%.]+ (%d+)'))
    if not code then return nil, 'no status' end
    return true, code
end

-- HTTPS GET that reads the FULL response body (for //ottoswap pull). Returns code, body or nil,err.
local function https_get(host, port, path)
    local deadline = socket.gettime() + 30
    local conn, err = tls_dial(host, port, deadline)
    if not conn then return nil, err end
    local request = 'GET ' .. path .. ' HTTP/1.1\r\nHost: ' .. host ..
        '\r\nUser-Agent: ottoswap-bridge/' .. _addon.version .. '\r\nConnection: close\r\n\r\n'
    local ok, serr = send_all(conn, request, deadline)
    if not ok then conn:close(); return nil, serr end
    local resp = ''   -- read until the server closes (relay sends Connection: close)
    while true do
        local data, recv_err, partial = conn:receive(4096)
        if data then resp = resp .. data
        elseif recv_err == 'closed' then resp = resp .. (partial or ''); break
        elseif recv_err == 'timeout' or recv_err == 'wantread' or recv_err == 'wantwrite' then
            resp = resp .. (partial or ''); coroutine.sleep(YIELD)
        else conn:close(); return nil, 'recv: ' .. tostring(recv_err) end
        if socket.gettime() > deadline then conn:close(); return nil, 'recv timeout' end
    end
    conn:close()
    local code = tonumber(resp:match('HTTP/[%d%.]+ (%d+)'))
    local body = resp:match('\r\n\r\n(.*)$') or ''
    return code, body
end

-- Post in the background: schedule the upload as a coroutine so prerender returns instantly, then
-- invoke on_done(success, code) when it finishes. success already folds in the 200/204 check.
local function post(path, body, on_done, extra_headers)
    local scheme, host, port = parse_endpoint(settings.endpoint)
    if not scheme then on_done(false, 'bad endpoint'); return end
    coroutine.schedule(function()
        local ok, code = https_post(host, port, path, body, extra_headers)
        on_done(ok and (code == 200 or code == 204), code)
    end, 0)
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

-- FFXI job abbreviations — used to recognize gear files that don't follow the Selindrile
-- naming the website parses.
local ffxi_jobs = {
    war = true, mnk = true, whm = true, blm = true, rdm = true, thf = true, pld = true,
    drk = true, bst = true, brd = true, rng = true, sam = true, nin = true, drg = true,
    smn = true, blu = true, cor = true, pup = true, dnc = true, sch = true, geo = true, run = true,
}

-- The website parses gear files named <Char>_<Job>_Gear.lua. Selindrile files already match and
-- pass through. Some setups instead lay sets out as <Char>/<job>.lua (just the job as the
-- filename, optionally with a _gear suffix) — rewrite those so they're recognized. Anything that
-- isn't a recognizable gear file (globals/includes) is sent untouched (the parser reads it for
-- cross-file item variables).
local function normalize_set_path(relpath)
    if relpath:lower():match('_[a-z]+_gear%.lua$') then return relpath end
    local char, file = relpath:match('^([^/]+)/([^/]+)%.lua$')
    if char and file then
        local job = file:gsub('_[gG][eE][aA][rR]$', '')
        -- keep the <Char>/ folder so the website's "skip the Selindrile template" filter still
        -- works (it matches the leading folder), and build the filename the parser expects
        if ffxi_jobs[job:lower()] then return char .. '/' .. char .. '_' .. job .. '_Gear.lua' end
    end
    return relpath
end

local function build_sets_json()
    local sets = {}
    collect_sets(windower.windower_path .. 'addons/GearSwap/data/', '', sets, 0)
    local parts = {}
    for relpath, content in pairs(sets) do
        parts[#parts + 1] = json_string(normalize_set_path(relpath)) .. ':' .. json_string(content)
    end
    if #parts == 0 then return nil end
    return '{' .. table.concat(parts, ',') .. '}'
end

-- Change-detection + delta. Walk the data tree into a manifest map (relpath -> "size:mtime") using
-- stats only — no content read. A change re-reads only the files that actually changed and pushes a
-- small delta of just those, instead of the whole ~1.7MB tree. State (the manifest + a version sig)
-- is shared across the 6 co-located instances via data/.sets-state, so a sibling's push dedups the
-- rest. Augments are unaffected — they ride the live channel's extdata, not these files.
local function file_stat(path)
    if lfs_ok then
        local a = lfs.attributes(path)
        if a then return a.size, a.modification end
    end
    local f = io.open(path, 'r')
    if not f then return nil end
    local size = f:seek('end')   -- size without reading the body
    f:close()
    return size, nil
end

local function scan_manifest(dir, prefix, acc, depth)
    if depth > 6 then return end
    for _, name in ipairs(windower.get_dir(dir) or {}) do
        local full = dir .. name
        if windower.dir_exists(full) then
            scan_manifest(full .. '/', prefix .. name .. '/', acc, depth + 1)
        elseif name:sub(-4):lower() == '.lua' then
            local size, mtime = file_stat(full)
            if size then acc[prefix .. name] = size .. ':' .. (mtime or '?') end
        end
    end
end
local function current_manifest()
    local m = {}
    scan_manifest(windower.windower_path .. 'addons/GearSwap/data/', '', m, 0)
    return m
end

-- djb2 hash of the sorted manifest -> short version token. The relay stores it opaquely as the
-- delta "base"; any content edit changes a file's size/mtime, so the token changes too.
local function manifest_sig(m)
    local keys = {}
    for k in pairs(m) do keys[#keys + 1] = k end
    table.sort(keys)
    local h = 5381
    for _, k in ipairs(keys) do
        local line = k .. ':' .. m[k] .. '\n'
        for i = 1, #line do h = (h * 33 + line:byte(i)) % 4294967296 end
    end
    return string.format('%08x', h)
end

-- Persisted state (shared across instances): data/.sets-state. Line 1 sig=<token>, line 2
-- since_full=<n> (deltas since the last full push), then one "relpath:size:mtime" line per file.
local function state_path()
    return windower.windower_path .. 'addons/' .. _addon.name .. '/data/.sets-state'
end
local function load_state()
    local f = io.open(state_path(), 'r')
    if not f then return nil end
    local content = f:read('*a'); f:close()
    if not content or content == '' then return nil end
    local sig, since_full, manifest = nil, 0, {}
    for line in content:gmatch('[^\n]+') do
        if line:sub(1, 4) == 'sig=' then sig = line:sub(5)
        elseif line:sub(1, 11) == 'since_full=' then since_full = tonumber(line:sub(12)) or 0
        else
            local relpath, sm = line:match('^([^:]+):(.+)$')   -- relpath has no ':'; sm = "size:mtime"
            if relpath then manifest[relpath] = sm end
        end
    end
    if not sig then return nil end
    return { sig = sig, since_full = since_full, manifest = manifest }
end
local function save_state(sig, since_full, manifest)
    local f = io.open(state_path(), 'w')
    if not f then return end
    f:write('sig=' .. sig .. '\nsince_full=' .. since_full .. '\n')
    local keys = {}
    for k in pairs(manifest) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(k .. ':' .. manifest[k] .. '\n') end
    f:close()
end

local RECONCILE_EVERY = 50   -- force a full push every N deltas as a ground-truth backstop

-- Build the delta envelope: changed/added file CONTENTS + removed keys, plus the full expected
-- normalized key-set for the relay's integrity cross-check. Reads only the changed files.
local function build_delta(base_sig, new_sig, prev, cur)
    local data_dir = windower.windower_path .. 'addons/GearSwap/data/'
    local cur_keys = {}   -- normalized key -> true (the resulting key-set)
    for raw in pairs(cur) do cur_keys[normalize_set_path(raw)] = true end
    local changed = {}
    for raw, sm in pairs(cur) do
        if prev[raw] ~= sm then
            local content = read_file(data_dir .. raw)
            if content then changed[#changed + 1] = json_string(normalize_set_path(raw)) .. ':' .. json_string(content) end
        end
    end
    local removed = {}
    for raw in pairs(prev) do
        if not cur[raw] then
            local nk = normalize_set_path(raw)
            if not cur_keys[nk] then removed[#removed + 1] = json_string(nk) end   -- only if no current file maps to it
        end
    end
    local keys = {}
    for nk in pairs(cur_keys) do keys[#keys + 1] = nk end
    table.sort(keys)
    local key_parts = {}
    for _, nk in ipairs(keys) do key_parts[#key_parts + 1] = json_string(nk) end
    return '{"base":' .. json_string(base_sig) .. ',"sig":' .. json_string(new_sig) ..
        ',"keys":[' .. table.concat(key_parts, ',') .. ']' ..
        ',"changed":{' .. table.concat(changed, ',') .. '}' ..
        ',"removed":[' .. table.concat(removed, ',') .. ']}'
end

local function push_sets(force, on_done)   -- on_done() fires after a successful push (full or delta)
    if settings.token == '' then return end
    local manifest = current_manifest()
    local sig = manifest_sig(manifest)
    local saved = load_state()   -- shared file; a sibling instance's push dedups the rest
    if not force and saved and saved.sig == sig then return end   -- nothing changed
    -- watchdog: clear a stuck in-flight flag if a prior push coroutine died without completing
    if state.sets_pushing and (os.time() - (state.sets_push_started or 0)) > 90 then state.sets_pushing = false end
    if state.sets_pushing then return end   -- a push is already in flight; the next scan retries
    state.sets_pushing = true
    state.sets_push_started = os.time()

    local function full_push()
        local body = build_sets_json()
        if not body then state.sets_pushing = false; return end
        post('/sets/' .. settings.token, body, function(success, code)
            state.sets_pushing = false
            if success then save_state(sig, 0, manifest); if on_done then on_done() end
            elseif force then log('sets push failed (' .. tostring(code) .. ')') end
        end, 'X-Ottoswap-Sig: ' .. sig .. '\r\n')
    end

    -- delta when we have a base, haven't hit the reconcile interval, and aren't force-pushing
    if not force and saved and saved.manifest and (saved.since_full or 0) < RECONCILE_EVERY then
        local envelope = build_delta(saved.sig, sig, saved.manifest, manifest)
        local since = (saved.since_full or 0) + 1
        post('/sets/' .. settings.token .. '/delta', envelope, function(success, code)
            if success then state.sets_pushing = false; save_state(sig, since, manifest); if on_done then on_done() end
            elseif code == 409 then full_push()   -- relay rejected (stale/no base/keyset) -> resync with a full push
            else state.sets_pushing = false end
        end)
    else
        full_push()
    end
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
            -- extdata returns a raw "System: N ID: N Val: N" descriptor for augments it can't
            -- name; it carries no usable stat, so don't forward it.
            if augment and augment ~= 'none' and augment ~= ''
               and not augment:match('^System:%s*%d+%s*ID:%s*%d+%s*Val:') then
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
    local owned = {}   -- id -> augjson ('' if none); drives the slot-independent change signature
    local equip_parts = {}
    for windower_key, slot_name in pairs(equipment_slots) do
        local index = all.equipment[windower_key]
        local bag_id = all.equipment[windower_key .. '_bag']
        if index and index > 0 then
            local bag = windower.ffxi.get_items(bag_id)
            local item = bag and bag[index]
            if item and item.id and item.id > 0 then
                local augments = item_augments_json(item)
                owned[item.id] = augments or ''
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
                if item and item.id and item.id > 0 and is_gear(item.id) then
                    local augments = item_augments_json(item)
                    owned[item.id] = augments or ''
                    item_parts[#item_parts + 1] = '[' .. item.id .. ',' .. (item.count or 1) ..
                        (augments and (',' .. augments) or '') .. ']'
                end
            end
            bag_parts[#bag_parts + 1] = '"' .. bag_name .. '":[' .. table.concat(item_parts, ',') .. ']'
        end
    end
    -- change signature: the SET of owned items + their augments, order/slot-independent. Gear
    -- swaps during combat just move items between slots/bags, so this stays stable — we only push
    -- when you actually gain/lose/augment gear (not on every swap). Huge cut to request volume.
    local ids = {}
    for id in pairs(owned) do ids[#ids + 1] = id end
    table.sort(ids)
    local sig = {}
    for _, id in ipairs(ids) do sig[#sig + 1] = id .. ':' .. owned[id] end
    local json = '"equipment":{' .. table.concat(equip_parts, ',') .. '},' ..
                 '"bags":{' .. table.concat(bag_parts, ',') .. '}'
    return json, table.concat(sig, ';')
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
    local gear, gear_sig = gear_json()
    if not gear then return nil end
    local body = '{"char":' .. json_string(player.name) .. ',' .. gear .. ',' .. stats_json() .. '}'
    -- include job + level in the signature so a job change re-pushes; volatile stats (buffs/food)
    -- are deliberately excluded so they don't trigger pushes
    local sig = (gear_sig or '') .. '|' .. tostring(player.main_job) .. tostring(player.main_job_level)
    return body, sig
end

local function push_live(force)
    if settings.token == '' then return end
    local body, sig = build_live()
    if not body then return end
    -- event-driven: push ONLY when the set of owned items/augments changed (no heartbeat, no
    -- idle traffic). The local 15s scan is free (it reads the game, not the network).
    if not force and sig == state.last_live_sig then return end
    if state.live_pushing and (os.time() - (state.live_push_started or 0)) > 90 then state.live_pushing = false end
    if state.live_pushing then return end
    state.live_pushing = true
    state.live_push_started = os.time()
    post('/push/' .. settings.token, body, function(success, code)
        state.live_pushing = false
        if success then state.last_live_sig = sig
        elseif force then log('live push failed (' .. tostring(code) .. ')') end
    end)
end

-- ---------------------------------------------------------------------------
-- Write-back: apply edits made on the website, pulled on the user's explicit //ottoswap pull.
-- ---------------------------------------------------------------------------
-- Parse the relay's length-prefixed pending-writes body: "<path>\n<bytelen>\n<raw content>" per file.
local function parse_writes(body)
    local writes, pos, n = {}, 1, #body
    while pos <= n do
        local nl1 = body:find('\n', pos, true)
        if not nl1 then break end
        local relpath = body:sub(pos, nl1 - 1)
        local nl2 = body:find('\n', nl1 + 1, true)
        if not nl2 then break end
        local len = tonumber(body:sub(nl1 + 1, nl2 - 1))
        if not len then break end
        writes[#writes + 1] = { path = relpath, content = body:sub(nl2 + 1, nl2 + len) }
        pos = nl2 + 1 + len
    end
    return writes
end

-- Write one edited file to its REAL on-disk path (the caller resolves the website key -> the real
-- file from the current scan, so no layout is assumed). Re-validates the path (the relay checks
-- too): a plain relative .lua under the data tree, never a traversal or absolute path. Keeps a
-- single rolling rollback copy in the bridge's OWN data folder — overwritten each time so it never
-- accumulates, and never under GearSwap/data so it's never synced.
local function apply_write(relpath, content)
    if not relpath:match('^[%w _%.%-/]+%.lua$') or relpath:find('%.%.') or relpath:sub(1, 1) == '/' then
        log('skipped unsafe path: ' .. tostring(relpath)); return false
    end
    local full = windower.windower_path .. 'addons/GearSwap/data/' .. relpath
    local existing = read_file(full)
    if existing then
        local bakname = relpath:gsub('[/\\]', '#')   -- flatten to one file per set, no subdirs
        local bak = io.open(windower.windower_path .. 'addons/' .. _addon.name .. '/data/wb-rollback-' .. bakname, 'w')
        if bak then bak:write(existing); bak:close() end   -- overwrites the previous rollback of this file
    end
    local f = io.open(full, 'w')
    if not f then log('write failed: ' .. relpath); return false end
    f:write(content); f:close()
    return true
end

-- The //ottoswap pull worker (runs as a coroutine — its network calls yield).
local function pull_writes()
    local scheme, host, port = parse_endpoint(settings.endpoint)
    if not scheme then log('bad endpoint'); return end
    local code, body = https_get(host, port, '/wb/' .. settings.token)
    if code ~= 200 then log('pull failed (' .. tostring(code) .. ')'); return end
    local writes = parse_writes(body or '')
    if #writes == 0 then log('no pending edits.'); return end
    -- resolve each website-facing key back to the REAL file in this player's tree (dynamic, no
    -- assumed layout): map normalize_set_path(rawfile) -> rawfile from a fresh scan.
    local resolve = {}
    for raw in pairs(current_manifest()) do resolve[normalize_set_path(raw)] = raw end
    local applied = 0
    for _, w in ipairs(writes) do
        if apply_write(resolve[w.path] or w.path, w.content) then applied = applied + 1 end
    end
    if applied > 0 then
        windower.send_command('gs reload')   -- reload GearSwap so the edits take effect
        log('applied ' .. applied .. ' edit(s), reloaded GearSwap.')
        -- re-push the changed sets so the relay (and the website) reflect the new gear, then clear
        -- the queue once the push lands -- the site refreshes off the queue emptying, so acking only
        -- after the push avoids the website reading stale sets. force-push: a same-size edit wouldn't
        -- move the size:mtime manifest on installs without lfs, so don't rely on delta detection here.
        push_sets(true, function()
            https_post(host, port, '/wb/' .. settings.token .. '/ack', '')   -- idempotent if lost; next pull re-applies
        end)
    else
        log('no edits applied.')
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
-- On load, remind you of your code (and keep the recovery file fresh) so a forgotten code
-- is never a dead end — the pairing persists across sessions, you just need to see it.
windower.register_event('load', function()
    math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
    -- stagger the first sets scan a few seconds so multiboxed clients don't hit it in lockstep
    state.last_sets_check = os.clock() - settings.sets_interval + 2 + math.random() * 18
    if settings.token ~= '' then
        write_code_file()
        log('v' .. _addon.version .. ' paired with code: ' .. settings.token .. '   (//ottoswap code for the pairing link)')
    else
        log('not paired. get a code at ' .. settings.site .. ', then: //ottoswap setup <code>')
    end
end)

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
            -- save to the GLOBAL section ('all'), not the per-character one config defaults to,
            -- so every character on a multiboxed install inherits the pairing — one //ottoswap
            -- setup pairs them all (otherwise each box reads a blank token and never pushes).
            settings:save('all')
            write_code_file()   -- save the code where you can find it again
            log('paired with code: ' .. settings.token)
            log('saved to addons/' .. _addon.name .. '/your-ottoswap-code.txt')
            log('sending your sets + gear to ottoswap.')
            push_sets(true)
            push_live(true)
        else
            log('usage: //ottoswap setup <pairing-code>')
        end
    elseif command == 'code' or command == 'mycode' then
        if settings.token ~= '' then
            write_code_file()   -- refresh the file in case it was deleted
            log('your code: ' .. settings.token)
            log('pair a device: ' .. pairing_link())
        else
            log('not paired yet — run //ottoswap setup <code> (the code is on the website)')
        end
    elseif command == 'endpoint' then
        if args[1] then settings.endpoint = args[1]; settings:save('all'); log('endpoint set to ' .. settings.endpoint) end
    elseif command == 'push' then
        push_sets(true); push_live(true); log('pushed.')
    elseif command == 'pull' then
        if settings.token == '' then
            log('not paired. run //ottoswap setup <code>')
        else
            log('checking ottoswap for edits to apply...')
            coroutine.schedule(pull_writes, 0)
        end
    elseif command == 'status' then
        if settings.token ~= '' then
            log('paired. your code: ' .. settings.token)
            log('pair a device: ' .. pairing_link())
        else
            log('not paired. run //ottoswap setup <code>')
        end
    else
        log('commands: setup <code> | code | push | pull | status | endpoint <url>')
    end
end)
