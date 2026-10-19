-- Internal function only: intentionally no network event or public export.
local queue, busy, sequence = {}, false, 0
local config = CompanyLogsConfig
local function clean(value, limit)
    local text = tostring(value or 'unknown'):gsub('[%z\1-\31\127]', ' ')
    local ok, offset = pcall(utf8.offset, text, limit + 1)
    if not ok then return '[invalid text]' end
    if offset then text = text:sub(1, offset - 1) end
    return text
end
local function webhook(category)
    local key = config.Categories[category]
    local url = key and GetConvar(key, '') or ''
    if url == '' then url = GetConvar(config.DefaultConvar, '') end
    -- HTTPS Discord webhook endpoints only, no userinfo, query, redirect or arbitrary hosts.
    if url:match('^https://discord%.com/api/webhooks/%d+/[%w_%-]+$')
        or url:match('^https://discord%.com/api/v%d+/webhooks/%d+/[%w_%-]+$') then return url end
end
local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == name then return value end
    end
    return nil
end
local pump
pump = function()
    if busy or #queue == 0 then return end
    busy = true
    local item = queue[1]
    item.attempts = item.attempts + 1
    local function completed(status, body, headers)
        local delay = 2000
        local retry = false
        if status == 429 then
            local ok, data = pcall(json.decode, body or '')
            local seconds = ok and type(data) == 'table' and tonumber(data.retry_after) or nil
            seconds = seconds or tonumber(header(headers, 'retry-after')) or 5
            if seconds ~= seconds or seconds <= 0 then seconds = 5 end
            delay = math.ceil(math.min(seconds, 3600) * 1000) + 250
            retry = item.attempts < 4
        elseif status <= 0 or status >= 500 then
            retry = item.attempts < 4
            delay = item.attempts * 5000
        end
        if not retry then
            table.remove(queue, 1)
            if status < 200 or status >= 300 then
                -- Never print URLs, tokens, payloads or HTTP response bodies.
                print(('[companyjob logs] Discord delivery failed (HTTP %s); event dropped.'):format(tostring(status)))
            end
        end
        local remaining = tonumber(header(headers, 'x-ratelimit-remaining'))
        local reset = tonumber(header(headers, 'x-ratelimit-reset-after'))
        if remaining == 0 and reset and reset == reset and reset > 0 then
            delay = math.max(delay, math.ceil(math.min(reset, 3600) * 1000) + 250)
        end
        SetTimeout(delay, function() busy = false pump() end)
    end
    local ok = pcall(PerformHttpRequest, item.url .. '?wait=true', function(status, body, headers)
        completed(tonumber(status) or 0, body, headers)
    end, 'POST', item.body, {['Content-Type'] = 'application/json'}, {followLocation = false})
    if not ok then completed(0, '', {}) end
end

function CompanyLog(category, title, player, details)
    -- Logging failures must not break a successful gameplay operation.
    local ok = pcall(function()
        if not config or not config.Enabled then return end
        local url = webhook(category)
        if not url then return end -- no webhook configured: no network requests
        if #queue >= 200 then
            if GetGameTimer() - (CompanyLogQueueWarning or -60000) >= 60000 then
                CompanyLogQueueWarning = GetGameTimer()
                print('[companyjob logs] Queue full; new events dropped.')
            end
            return
        end
        sequence = sequence + 1
        local fields = {
            {name = 'Player', value = clean(player and player.name or 'unknown', 100), inline = true},
            {name = 'Server ID', value = clean(player and player.source, 20), inline = true},
            {name = 'Grade', value = clean(player and player.job and player.job.grade_name, 60), inline = true}
        }
        if config.IncludeIdentifier then
            fields[#fields + 1] = {name = 'Identifier', value = clean(player and player.identifier, 100)}
        end
        for _, field in ipairs(details or {}) do
            if #fields >= 16 then break end
            fields[#fields + 1] = {name = clean(field[1], 80), value = clean(field[2], 240), inline = false}
        end
        local payload = {
            username = clean(config.Username, 60),
            embeds = {{title = clean(title, 180), color = 3447003, fields = fields,
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                footer = {text = ('esx_companyjob | %s | %s-%s'):format(category, os.time(), sequence)}}}
        }
        -- Explicit JSON empty array prevents accidental mentions regardless of empty-table encoding.
        local body = json.encode(payload):gsub('^{', '{"allowed_mentions":{"parse":[]},', 1)
        queue[#queue + 1] = {url = url, body = body, attempts = 0}
        pump()
    end)
    if not ok then print('[companyjob logs] Could not prepare audit event; gameplay continues.') end
end
