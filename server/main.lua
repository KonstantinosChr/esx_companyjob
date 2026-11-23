local ESX
do
    local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok and obj then
        ESX = obj
    else
        TriggerEvent('esx:getSharedObject', function(shared) ESX = shared end)
    end
end

local JOB = 'companyjob'
local MAX_CONVOY_MEMBERS = Config.MaxConvoyMembers or 8
local REGISTRATION_TIMEOUT = (Config.ConvoyRegistrationTimeout or 45) * 60
local MIN_DELIVERY_SECONDS = Config.MinDeliverySeconds or 180

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function validInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value and value >= minimum
        and value <= maximum and value % 1 == 0
end

local function validName(value)
    return type(value) == 'string' and #value > 0 and #value <= 64
end

local function truthy(value)
    return value == true or value == 1
end

local function toVector(pos)
    return vector3(pos.x, pos.y, pos.z)
end

-- Online players' identifiers, kept so cleanup works after ESX has released a player.
local identifierBySource = {}

local function getPlayer(source)
    local player = ESX.GetPlayerFromId(source)
    if player then identifierBySource[source] = player.identifier end
    return player
end

local function onlineIdentifiers()
    local set = {}
    for source, identifier in pairs(identifierBySource) do
        if GetPlayerName(source) then set[identifier] = true end
    end
    return set
end

local function isEmployee(player)
    return player ~= nil and player.job.name == JOB
end

local function isOfficer(player)
    return isEmployee(player)
        and (player.job.grade_name == 'boss' or player.job.grade_name == 'underboss')
end

local function weaponAmmo(player, name)
    for _, weapon in ipairs(player.getLoadout()) do
        if weapon.name == name then return weapon.ammo end
    end
end

local function canCarry(player, item, count)
    if player.canCarryItem then return player.canCarryItem(item, count) end
    local entry = player.getInventoryItem(item)
    return entry and (entry.limit == -1 or
        (type(entry.limit) == 'number' and entry.count + count <= entry.limit))
end

local function playerInventory(player)
    if player.getInventory then return player.getInventory() end
    return player.inventory
end

local function notify(target, message)
    TriggerClientEvent('esx:showNotification', target, message)
end

-- Triggers a callback-style server event and waits for its answer, with a timeout,
-- so a missing dependency cannot leave a client callback unanswered forever.
local function awaitEvent(eventName, timeout, ...)
    local p, done = promise.new(), false
    local function finish(value)
        if done then return end
        done = true
        p:resolve(value)
    end
    local args = table.pack(...)
    args[args.n + 1] = finish
    TriggerEvent(eventName, table.unpack(args, 1, args.n + 1))
    if not done then SetTimeout(timeout, function() finish(nil) end) end
    return Citizen.Await(p)
end

local function resourceStarted(name)
    return GetResourceState(name) == 'started'
end

local function IsPlayerNearCoords(source, coords, maxDist)
    local ped = GetPlayerPed(source)
    if not DoesEntityExist(ped) then return false end
    return #(GetEntityCoords(ped) - toVector(coords)) <= maxDist
end

local function IsPlayerNearTarget(source, target, maxDist)
    if not validInteger(target, 1, 65535) or target == source
        or not ESX.GetPlayerFromId(target)
        or GetPlayerRoutingBucket(source) ~= GetPlayerRoutingBucket(target) then return false end
    local sourcePed, targetPed = GetPlayerPed(source), GetPlayerPed(target)
    if not DoesEntityExist(sourcePed) or not DoesEntityExist(targetPed) then return false end
    return #(GetEntityCoords(sourcePed) - GetEntityCoords(targetPed)) <= maxDist
end

local function storageAllowed(source, player, storing)
    if not isEmployee(player) then return false end
    if storing == 'society_companyjob' then
        return IsPlayerNearCoords(source, Config.Zones.BossActions.Pos, 15.0)
    elseif storing == 'society_companyjob_depot' then
        return player.job.grade_name ~= 'recruit'
            and IsPlayerNearCoords(source, Config.Zones.StorageDepot.Pos, 15.0)
    end
    return false
end

-- Per-player, per-entry-point throttle. Not a substitute for authorization.
local requestTimes = {}
local function acceptRequest(source, name)
    if not validInteger(source, 1, 65535) then return false end
    local now = GetGameTimer()
    requestTimes[source] = requestTimes[source] or {}
    local last = requestTimes[source][name]
    if last and now - last < 300 then return false end
    requestTimes[source][name] = now
    return true
end

local function registerCallback(name, fallback, handler)
    ESX.RegisterServerCallback(name, function(source, cb, ...)
        if not acceptRequest(source, name) then cb(fallback) return end
        handler(source, cb, ...)
    end)
end

local function registerNetworkHandler(name, handler)
    RegisterNetEvent(name, function(...)
        local src = source
        if acceptRequest(src, name) then handler(src, ...) end
    end)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

if Config.MaxInService ~= -1 then
    TriggerEvent('esx_service:activateService', JOB, Config.MaxInService)
end

TriggerEvent('esx_phone:registerNumber', JOB, _U('alert_companyjob'), true, true)
TriggerEvent('esx_society:registerSociety', JOB, 'Company Job', 'society_companyjob', 'society_companyjob', 'society_companyjob', { type = 'public' })

AddEventHandler('esx:playerLoaded', function(playerId, xPlayer)
    if xPlayer then identifierBySource[playerId] = xPlayer.identifier end
end)

CreateThread(function()
    for _, playerId in ipairs(ESX.GetPlayers()) do getPlayer(tonumber(playerId)) end
end)

-- ---------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------

local function getPriceFromHash(hashKey, jobGrade, vType)
    if vType ~= 'car' then return 0 end
    local wanted = hashKey % 4294967296
    for _, list in ipairs({ Config.AuthorizedVehicles[jobGrade] or {}, Config.AuthorizedVehicles.Shared or {} }) do
        for _, vehicle in ipairs(list) do
            if GetHashKey(vehicle.model) % 4294967296 == wanted then return vehicle.price end
        end
    end
    return 0
end

-- Garage integration still relies on the external vehicleshop checkout handler.
registerCallback('companyjob:storeNearbyVehicle', false, function(source, cb, nearbyVehicles)
    local player = getPlayer(source)
    if not isEmployee(player)
        or not IsPlayerNearCoords(source, Config.Zones.CarGarage.Pos, 40.0)
        or type(nearbyVehicles) ~= 'table' or #nearbyVehicles > 32 then cb(false) return end
    local ped = GetPlayerPed(source)
    for index, entry in ipairs(nearbyVehicles) do
        if type(entry) == 'table' and validInteger(entry.netId, 1, 2147483647) then
            local entity = NetworkGetEntityFromNetworkId(entry.netId)
            if entity ~= 0 and DoesEntityExist(entity) and GetEntityType(entity) == 2
                and GetEntityRoutingBucket(entity) == GetPlayerRoutingBucket(source)
                and #(GetEntityCoords(entity) - GetEntityCoords(ped)) <= 35.0 then
                local plate = (GetVehicleNumberPlateText(entity) or ''):match('^%s*(.-)%s*$')
                -- Reject vehicles occupied by any connected player.
                local occupied = false
                for _, id in ipairs(GetPlayers()) do
                    if GetVehiclePedIsIn(GetPlayerPed(tonumber(id)), false) == entity then occupied = true break end
                end
                if not occupied then
                    local changed = MySQL.update.await('UPDATE owned_vehicles SET stored = 1, in_garage_type = ?, put_by = ? WHERE plate = ? AND job = ? AND stored = 0',
                        { JOB, player.identifier, plate, JOB })
                    if changed == 1 then
                        DeleteEntity(entity)
                        CompanyLog('vehicles', 'Company vehicle stored', player, {{'Plate', plate}})
                        cb(true, index) return
                    end
                end
            end
        end
    end
    cb(false)
end)

local purchasePending = {}
registerCallback('companyjob:buyJobVehicle', false, function(source, cb, props, kind)
    local player = getPlayer(source)
    if not isEmployee(player) or player.job.grade_name ~= 'boss'
        or purchasePending[player.identifier] or type(props) ~= 'table' or kind ~= 'car'
        or not validInteger(props.model, -2147483648, 4294967295)
        or type(props.plate) ~= 'string' or #props.plate < 1 or #props.plate > 8
        or not props.plate:match('^[A-Z0-9 ]+$')
        or not IsPlayerNearCoords(source, Config.Zones.CarGarage.InsideShop, 20.0) then cb(false) return end
    local price = getPriceFromHash(props.model, player.job.grade_name, kind)
    if price <= 0 then cb(false) return end
    purchasePending[player.identifier] = true
    local debited = false
    local ok, result = pcall(function()
        if MySQL.scalar.await('SELECT plate FROM owned_vehicles WHERE plate = ?', { props.plate }) then return false end
        if ESX.GetPlayerFromId(source) ~= player or player.getMoney() < price then return false end
        player.removeMoney(price)
        debited = true
        -- Do not persist arbitrary client upgrades or vehicle properties.
        local changed = MySQL.update.await('INSERT INTO owned_vehicles (owner, vehicle, plate, type, job, stored, in_garage_type, put_by) VALUES (?, ?, ?, ?, ?, 1, ?, ?)',
            { player.identifier, json.encode({ model = props.model, plate = props.plate }), props.plate, kind, JOB, JOB, player.identifier })
        return changed == 1
    end)
    purchasePending[player.identifier] = nil
    if not ok or not result then
        if debited then player.addMoney(price) end
        cb(false) return
    end
    CompanyLog('vehicles', 'Company vehicle purchased', player, {{'Plate', props.plate}, {'Model hash', props.model}, {'Cash charged', price}})
    cb(true)
end)

-- ---------------------------------------------------------------------------
-- Company vault & depot
-- ---------------------------------------------------------------------------

local EMPTY_STOCK = { items = {}, weapons = {} }

registerCallback('companyjob:getStockItems', EMPTY_STOCK, function(source, cb, storing)
    local xPlayer = getPlayer(source)
    if not storageAllowed(source, xPlayer, storing) then cb(EMPTY_STOCK) return end
    local inventory = awaitEvent('esx_addoninventory:getSharedInventory', 2000, storing)
    local store = awaitEvent('esx_datastore:getSharedDataStore', 2000, storing)
    cb({
        items = inventory and inventory.items or {},
        weapons = store and store.get('weapons') or {},
    })
end)

registerCallback('companyjob:getPlayerInventory', EMPTY_STOCK, function(source, cb)
    local xPlayer = getPlayer(source)
    if not xPlayer then cb(EMPTY_STOCK) return end
    cb({ items = playerInventory(xPlayer), weapons = xPlayer.getLoadout() })
end)

registerCallback('companyjob:takeStockItem', false, function(source, cb, itemType, itemName, count, storing)
    local xPlayer = getPlayer(source)
    if not storageAllowed(source, xPlayer, storing) or not validName(itemName) then cb(false) return end

    if itemType == 'item_weapon' then
        local store = awaitEvent('esx_datastore:getSharedDataStore', 2000, storing)
        if not store or ESX.GetPlayerFromId(source) ~= xPlayer or xPlayer.hasWeapon(itemName) then cb(false) return end
        local storeWeapons = store.get('weapons') or {}
        for i, weapon in ipairs(storeWeapons) do
            if weapon.name == itemName then
                table.remove(storeWeapons, i)
                store.set('weapons', storeWeapons)
                xPlayer.addWeapon(weapon.name, weapon.ammo or 0)
                CompanyLog('storage', 'Weapon withdrawn', xPlayer, {{'Storage', storing}, {'Weapon', weapon.name}, {'Ammo', weapon.ammo}})
                cb(true) return
            end
        end
        cb(false)
    elseif itemType == 'item_standard' and validInteger(count, 1, 1000000) then
        local inventory = awaitEvent('esx_addoninventory:getSharedInventory', 2000, storing)
        local inventoryItem = inventory and inventory.getItem(itemName)
        if not inventoryItem or inventoryItem.count < count or ESX.GetPlayerFromId(source) ~= xPlayer then
            notify(source, _U('quantity_invalid')) cb(false) return
        end
        if not canCarry(xPlayer, itemName, count) then
            notify(source, _U('cannot_carry')) cb(false) return
        end
        inventory.removeItem(itemName, count)
        xPlayer.addInventoryItem(itemName, count)
        CompanyLog('storage', 'Items withdrawn', xPlayer, {{'Storage', storing}, {'Item', itemName}, {'Count', count}})
        notify(source, _U('have_withdrawn', count, inventoryItem.label))
        cb(true)
    else
        cb(false)
    end
end)

registerCallback('companyjob:depositStockItem', false, function(source, cb, itemType, itemName, count, storing)
    local xPlayer = getPlayer(source)
    if not storageAllowed(source, xPlayer, storing) or not validName(itemName) then cb(false) return end

    if itemType == 'item_standard' and validInteger(count, 1, 1000000) then
        local inventory = awaitEvent('esx_addoninventory:getSharedInventory', 2000, storing)
        local inventoryItem = inventory and inventory.getItem(itemName)
        local sourceItem = xPlayer.getInventoryItem(itemName)
        if not inventoryItem or not sourceItem or sourceItem.count < count or ESX.GetPlayerFromId(source) ~= xPlayer then
            notify(source, _U('quantity_invalid')) cb(false) return
        end
        xPlayer.removeInventoryItem(itemName, count)
        inventory.addItem(itemName, count)
        CompanyLog('storage', 'Items deposited', xPlayer, {{'Storage', storing}, {'Item', itemName}, {'Count', count}})
        notify(source, _U('have_deposited', count, inventoryItem.label))
        cb(true)
    elseif itemType == 'item_weapon' then
        local store = awaitEvent('esx_datastore:getSharedDataStore', 2000, storing)
        if not store or ESX.GetPlayerFromId(source) ~= xPlayer or not xPlayer.hasWeapon(itemName) then cb(false) return end
        local ammo = weaponAmmo(xPlayer, itemName)
        if not validInteger(ammo, 0, 1000000) then cb(false) return end
        local storeWeapons = store.get('weapons') or {}
        storeWeapons[#storeWeapons + 1] = { name = itemName, ammo = ammo }
        store.set('weapons', storeWeapons)
        xPlayer.removeWeapon(itemName)
        CompanyLog('storage', 'Weapon deposited', xPlayer, {{'Storage', storing}, {'Weapon', itemName}, {'Ammo', ammo}})
        cb(true)
    else
        cb(false)
    end
end)

-- ---------------------------------------------------------------------------
-- Restraints: the server owns the handcuff state.
-- ---------------------------------------------------------------------------

local cuffs = {} -- [target] = { by = officerSource, token = n }
local cuffSequence = 0

local function setCuffed(target, value, officer)
    if value then
        cuffSequence = cuffSequence + 1
        cuffs[target] = { by = officer, token = cuffSequence }
        if Config.EnableHandcuffTimer then
            local token = cuffSequence
            SetTimeout(Config.HandcuffTimer or 600000, function()
                if cuffs[target] and cuffs[target].token == token then setCuffed(target, false) end
            end)
        end
    else
        cuffs[target] = nil
    end
    TriggerClientEvent('companyjob:handcuff', target, value and true or false)
end

local function isCuffed(target)
    return cuffs[target] ~= nil
end

local function officerNear(source, target)
    local xPlayer = getPlayer(source)
    if not isOfficer(xPlayer) then
        print(('companyjob: %s attempted a restricted interaction without permission'):format(xPlayer and xPlayer.identifier or source))
        return nil
    end
    if not IsPlayerNearTarget(source, target, 10.0) then return nil end
    return xPlayer
end

registerNetworkHandler('companyjob:handcuff', function(source, target)
    local xPlayer = officerNear(source, target)
    if not xPlayer then return end
    local cuff = not isCuffed(target)
    setCuffed(target, cuff, source)
    CompanyLog('interactions', cuff and 'Player handcuffed' or 'Player uncuffed', xPlayer, {{'Target ID', target}})
end)

registerNetworkHandler('companyjob:drag', function(source, target)
    if officerNear(source, target) and isCuffed(target) then
        TriggerClientEvent('companyjob:drag', target, source)
    end
end)

registerNetworkHandler('companyjob:putInVehicle', function(source, target)
    if officerNear(source, target) and isCuffed(target) then
        TriggerClientEvent('companyjob:putInVehicle', target)
    end
end)

registerNetworkHandler('companyjob:OutVehicle', function(source, target)
    if officerNear(source, target) and isCuffed(target) then
        TriggerClientEvent('companyjob:OutVehicle', target)
    end
end)

registerCallback('companyjob:getOtherPlayerData', false, function(source, cb, target)
    local xPlayer = officerNear(source, target)
    local targetXPlayer = xPlayer and ESX.GetPlayerFromId(target)
    if not targetXPlayer or not isCuffed(target) then cb(false) return end

    local data = {
        name = GetPlayerName(target),
        job = targetXPlayer.job,
        inventory = playerInventory(targetXPlayer),
        accounts = targetXPlayer.getAccounts and targetXPlayer.getAccounts() or targetXPlayer.accounts,
        weapons = targetXPlayer.getLoadout(),
    }

    if Config.EnableESXIdentity then
        local row = MySQL.single.await('SELECT firstname, lastname, sex, dateofbirth, height FROM users WHERE identifier = ?', { targetXPlayer.identifier }) or {}
        data.firstname = row.firstname or 'Unknown'
        data.lastname = row.lastname or 'Unknown'
        data.sex = row.sex or 'Unknown'
        data.dob = row.dateofbirth or 'Unknown'
        data.height = row.height or 'Unknown'
    end

    if resourceStarted('esx_status') then
        local status = awaitEvent('esx_status:getStatus', 2000, target, 'drunk')
        if status and status.percent then data.drunk = math.floor(status.percent) end
    end

    if Config.EnableLicenses and resourceStarted('esx_license') then
        data.licenses = awaitEvent('esx_license:getLicenses', 3000, target)
    end

    notify(target, _U('being_searched'))
    cb(data)
end)

registerCallback('companyjob:confiscate', false, function(source, cb, target, itemType, itemName, amount)
    local sourceXPlayer = officerNear(source, target)
    local targetXPlayer = sourceXPlayer and ESX.GetPlayerFromId(target)
    if not targetXPlayer or not isCuffed(target) or not validName(itemName) then cb(false) return end

    local function logged()
        CompanyLog('interactions', 'Player property confiscated', sourceXPlayer, {{'Target ID', target}, {'Type', itemType}, {'Item/account', itemName}, {'Count/ammo', amount}})
    end

    if itemType == 'item_standard' then
        if not validInteger(amount, 1, 1000000) then cb(false) return end
        local targetItem = targetXPlayer.getInventoryItem(itemName)
        if not targetItem or targetItem.count < amount then
            notify(source, _U('quantity_invalid')) cb(false) return
        end
        if not canCarry(sourceXPlayer, itemName, amount) then
            notify(source, _U('cannot_carry')) cb(false) return
        end
        targetXPlayer.removeInventoryItem(itemName, amount)
        sourceXPlayer.addInventoryItem(itemName, amount)
        logged()
        notify(source, _U('you_confiscated', amount, targetItem.label, targetXPlayer.name))
        notify(target, _U('got_confiscated', amount, targetItem.label, sourceXPlayer.name))
        cb(true)
    elseif itemType == 'item_account' then
        if itemName ~= 'black_money' or not validInteger(amount, 1, 1000000000) then cb(false) return end
        local targetAccount = targetXPlayer.getAccount(itemName)
        if not targetAccount or targetAccount.money < amount then cb(false) return end
        targetXPlayer.removeAccountMoney(itemName, amount)
        sourceXPlayer.addAccountMoney(itemName, amount)
        logged()
        notify(source, _U('you_confiscated_account', amount, itemName, targetXPlayer.name))
        notify(target, _U('got_confiscated_account', amount, itemName, sourceXPlayer.name))
        cb(true)
    elseif itemType == 'item_weapon' then
        if sourceXPlayer.hasWeapon(itemName) or not targetXPlayer.hasWeapon(itemName) then cb(false) return end
        amount = weaponAmmo(targetXPlayer, itemName)
        if not validInteger(amount, 0, 1000000) then cb(false) return end
        targetXPlayer.removeWeapon(itemName)
        sourceXPlayer.addWeapon(itemName, amount)
        logged()
        notify(source, _U('you_confiscated_weapon', ESX.GetWeaponLabel(itemName), targetXPlayer.name, amount))
        notify(target, _U('got_confiscated_weapon', ESX.GetWeaponLabel(itemName), amount, sourceXPlayer.name))
        cb(true)
    else
        cb(false)
    end
end)

-- ---------------------------------------------------------------------------
-- Convoys and deliveries
-- The database is the source of truth for registration, delivery and payment.
-- `runs` only tracks trailers that are currently out (lost on restart; the
-- trailers are deleted on stop, so nothing is left half-way).
-- ---------------------------------------------------------------------------

local runs = {}           -- [identifier] = { phase, owner, entity, started, convoy }
local registeredAt = {}   -- [identifier] = os.time() of the last registration/sync
local paying = {}         -- [identifier] = true while a payment is being processed
local convoyBusy = false

local function withConvoyLock(fn)
    local deadline = GetGameTimer() + 3000
    while convoyBusy do
        if GetGameTimer() > deadline then return false end
        Wait(50)
    end
    convoyBusy = true
    local ok, result = pcall(fn)
    convoyBusy = false
    if not ok then
        print(('[companyjob] convoy operation failed: %s'):format(tostring(result)))
        return false
    end
    return result
end

local function getRunRow(identifier)
    return MySQL.single.await('SELECT convoy_id, is_trailer_stored, is_paid FROM convoy_registered_list WHERE identifier = ?', { identifier })
end

local function deleteRunEntity(run)
    if run and run.entity and DoesEntityExist(run.entity) then DeleteEntity(run.entity) end
end

-- Frees convoys whose remaining members are all finished, offline or expired.
-- Delivered-but-unpaid rows are never reset, so the payment survives reconnects.
local function sweepConvoys()
    return withConvoyLock(function()
        local rows = MySQL.query.await('SELECT identifier, convoy_id, is_trailer_stored, is_paid FROM convoy_registered_list WHERE convoy_id > 0') or {}
        local online, now = onlineIdentifiers(), os.time()
        local convoys = {}
        for _, row in ipairs(rows) do
            local convoy = convoys[row.convoy_id] or { live = false, paid = {}, stale = {} }
            convoys[row.convoy_id] = convoy
            local stored, paid = truthy(row.is_trailer_stored), truthy(row.is_paid)
            if paid then
                convoy.paid[#convoy.paid + 1] = row.identifier
            elseif runs[row.identifier] then
                convoy.live = true
            elseif stored then
                if online[row.identifier] then convoy.live = true end
            elseif online[row.identifier] and registeredAt[row.identifier]
                and now - registeredAt[row.identifier] < REGISTRATION_TIMEOUT then
                convoy.live = true
            else
                convoy.stale[#convoy.stale + 1] = row.identifier
            end
        end
        for convoyId, convoy in pairs(convoys) do
            local reset = convoy.stale
            if not convoy.live then
                for _, identifier in ipairs(convoy.paid) do reset[#reset + 1] = identifier end
            end
            for _, identifier in ipairs(reset) do
                if not runs[identifier] then
                    MySQL.update.await('UPDATE convoy_registered_list SET convoy_id = 0, is_paid = 0, is_trailer_stored = 0 WHERE identifier = ? AND convoy_id = ? AND (is_paid = 1 OR is_trailer_stored = 0)',
                        { identifier, convoyId })
                    registeredAt[identifier] = nil
                end
            end
        end
        return true
    end)
end

local function sweepSoon()
    CreateThread(sweepConvoys)
end

-- id > 0 joins a convoy; id == 0 leaves it and cancels a trailer that is out.
local function registerConvoy(source, id)
    local player = getPlayer(source)
    if not isEmployee(player) or not validInteger(id, 0, 2147483647) then return false, 'invalid' end
    if id > 0 and not IsPlayerNearCoords(source, Config.Zones.ConvoiRegister.Pos, 15.0) then return false, 'invalid' end
    local identifier = player.identifier
    local run = runs[identifier]
    if run and not (id == 0 and run.phase == 'active' and run.owner == source) then return false, 'busy' end

    local reason
    local ok = withConvoyLock(function()
        local row = getRunRow(identifier)
        if row and truthy(row.is_trailer_stored) and not truthy(row.is_paid) then
            reason = 'unpaid' return false
        end
        if id > 0 then
            if not MySQL.scalar.await('SELECT id FROM convoy_list WHERE id = ?', { id }) then reason = 'invalid' return false end
            local count = MySQL.scalar.await('SELECT COUNT(*) FROM convoy_registered_list WHERE convoy_id = ? AND identifier <> ?', { id, identifier })
            if (tonumber(count) or 0) >= MAX_CONVOY_MEMBERS then reason = 'full' return false end
        end
        -- Re-check after the database yields.
        if ESX.GetPlayerFromId(source) ~= player or runs[identifier] ~= run
            or (run and run.phase ~= 'active') then reason = 'busy' return false end
        -- Reserve while the upsert yields, blocking trailer requests against a stale registration.
        runs[identifier] = { phase = 'registering', owner = source }
        local success = pcall(MySQL.update.await, 'INSERT INTO convoy_registered_list (identifier, convoy_id, is_paid, is_trailer_stored) VALUES (?, ?, 0, 0) ON DUPLICATE KEY UPDATE convoy_id = VALUES(convoy_id), is_paid = 0, is_trailer_stored = 0',
            { identifier, id })
        runs[identifier] = run
        return success
    end)
    if not ok then return false, reason or 'busy' end

    if run then
        deleteRunEntity(run)
        runs[identifier] = nil
        CompanyLog('deliveries', 'Delivery cancelled', player, {{'Convoy', run.convoy}})
    end
    registeredAt[identifier] = id > 0 and os.time() or nil
    CompanyLog('deliveries', id > 0 and 'Convoy joined' or 'Convoy left', player, {{'Convoy', id}})
    sweepSoon()
    return true
end

registerCallback('companyjob:joinConvoy', false, function(source, cb, id)
    if not validInteger(id, 1, 2147483647) then cb(false, 'invalid') return end
    cb(registerConvoy(source, id))
end)

registerCallback('companyjob:leaveConvoy', false, function(source, cb)
    cb(registerConvoy(source, 0))
end)

-- Lets the client restore its delivery state after a reconnect or resource restart.
registerCallback('companyjob:syncRun', false, function(source, cb)
    local player = getPlayer(source)
    if not isEmployee(player) then cb({ convoy = 0 }) return end
    local identifier = player.identifier
    local row = getRunRow(identifier)
    if not row or row.convoy_id <= 0 then cb({ convoy = 0 }) return end
    local stored, paid = truthy(row.is_trailer_stored), truthy(row.is_paid)
    if not stored and not registeredAt[identifier] then registeredAt[identifier] = os.time() end
    local run = runs[identifier]
    cb({
        convoy = row.convoy_id,
        trailerOut = run ~= nil and run.phase == 'active' and run.owner == source,
        awaitingPay = stored and not paid,
        finished = stored and paid,
    })
end)

-- Spawn on the server: a client cannot nominate an arbitrary trailer for a reward.
registerCallback('companyjob:spawnTrailer', false, function(source, cb)
    local player = getPlayer(source)
    if not isEmployee(player)
        or GetPlayerRoutingBucket(source) ~= 0
        or not IsPlayerNearCoords(source, Config.Zones.PopTrailer.Pos, 25.0) then cb(false) return end
    local identifier = player.identifier
    local existing = runs[identifier]
    -- A trailer that was destroyed or despawned can be re-issued instead of blocking the player.
    if existing and existing.phase == 'active' and existing.owner == source
        and not (existing.entity and DoesEntityExist(existing.entity)) then
        runs[identifier] = nil
        existing = nil
    end
    if existing then cb(false) return end

    local run = { phase = 'spawning', owner = source }
    runs[identifier] = run -- reserve before database yield
    local row = getRunRow(identifier)
    if not row or row.convoy_id <= 0 or truthy(row.is_trailer_stored)
        or ESX.GetPlayerFromId(source) ~= player or runs[identifier] ~= run then
        if runs[identifier] == run then runs[identifier] = nil end
        cb(false) return
    end
    local pos = Config.Trailer.Pos
    local entity = CreateVehicle(GetHashKey(Config.Trailer.Name), pos.x, pos.y, pos.z, Config.Trailer.Heading, true, true)
    local deadline = GetGameTimer() + 5000
    while not DoesEntityExist(entity) and GetGameTimer() < deadline do Wait(50) end
    if not DoesEntityExist(entity) or ESX.GetPlayerFromId(source) ~= player then
        if DoesEntityExist(entity) then DeleteEntity(entity) end
        if runs[identifier] == run then runs[identifier] = nil end
        cb(false) return
    end
    run.entity, run.started, run.convoy, run.phase = entity, os.time(), row.convoy_id, 'active'
    registeredAt[identifier] = os.time()
    CompanyLog('deliveries', 'Trailer issued', player, {{'Convoy', run.convoy}, {'Network ID', NetworkGetNetworkIdFromEntity(entity)}})
    cb(NetworkGetNetworkIdFromEntity(entity))
end)

local function awardDepotItems(player, convoy)
    local inventory = awaitEvent('esx_addoninventory:getSharedInventory', 2000, 'society_companyjob_depot')
    if not inventory or #Config.listItems == 0 then return end
    local totals = {}
    for _ = 1, 50 do
        local item, count = Config.listItems[math.random(1, #Config.listItems)], math.random(1, 10)
        inventory.addItem(item, count)
        totals[item] = (totals[item] or 0) + count
    end
    -- Item batches keep every awarded item visible without exceeding embed limits.
    local names = {}
    for name in pairs(totals) do names[#names + 1] = name end
    table.sort(names)
    for first = 1, #names, 10 do
        local fields = {{'Convoy', convoy}, {'Storage', 'society_companyjob_depot'}}
        for index = first, math.min(first + 9, #names) do
            fields[#fields + 1] = {names[index], totals[names[index]]}
        end
        CompanyLog('deliveries', 'Delivery depot rewards', player, fields)
    end
end

registerCallback('companyjob:deliverTrailer', false, function(source, cb)
    local player = getPlayer(source)
    local run = player and runs[player.identifier]
    local storePos = toVector(Config.Zones.StoreTrailer.Pos)
    if not isEmployee(player) or not run or run.owner ~= source
        or run.phase ~= 'active' or os.time() - run.started < MIN_DELIVERY_SECONDS
        or GetPlayerRoutingBucket(source) ~= 0
        or not IsPlayerNearCoords(source, Config.Zones.StoreTrailer.Pos, 25.0)
        or not DoesEntityExist(run.entity)
        or GetEntityModel(run.entity) ~= GetHashKey(Config.Trailer.Name)
        or #(GetEntityCoords(run.entity) - storePos) > 25.0
        then cb(false) return end
    run.phase = 'delivering' -- block concurrent delivery/cancel requests before yielding
    local changed = MySQL.update.await('UPDATE convoy_registered_list SET is_trailer_stored = 1 WHERE identifier = ? AND convoy_id = ? AND is_trailer_stored = 0 AND is_paid = 0',
        { player.identifier, run.convoy })
    if changed ~= 1 then run.phase = 'active' cb(false) return end
    deleteRunEntity(run)
    runs[player.identifier] = nil
    awardDepotItems(player, run.convoy)
    CompanyLog('deliveries', 'Trailer delivered', player, {{'Convoy', run.convoy}, {'Trip seconds', os.time() - run.started}})
    cb(true)
end)

registerCallback('companyjob:collectPay', false, function(source, cb)
    local xPlayer = getPlayer(source)
    if not isEmployee(xPlayer) or not IsPlayerNearCoords(source, Config.Zones.GetPaid.Pos, 20.0) then cb(false) return end
    local identifier = xPlayer.identifier
    if paying[identifier] then cb(false) return end
    paying[identifier] = true

    local ok, claim = pcall(function()
        local row = getRunRow(identifier)
        if not row or row.convoy_id <= 0 or not truthy(row.is_trailer_stored) or truthy(row.is_paid) then return false end
        local convoy = row.convoy_id
        local tier = tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM convoy_registered_list WHERE convoy_id = ? AND is_trailer_stored = 1', { convoy })) or 1
        tier = math.max(1, math.min(tier, #Config.Pay))
        -- Conditional claim: only one request can flip is_paid.
        local changed = MySQL.update.await('UPDATE convoy_registered_list SET is_paid = 1 WHERE identifier = ? AND convoy_id = ? AND is_paid = 0 AND is_trailer_stored = 1',
            { identifier, convoy })
        if changed ~= 1 then return false end
        return { convoy = convoy, tier = tier }
    end)
    paying[identifier] = nil
    if not ok or not claim then cb(false) return end

    if ESX.GetPlayerFromId(source) ~= xPlayer then
        -- The player left after the claim: undo it so the payment can be collected later.
        MySQL.update.await('UPDATE convoy_registered_list SET is_paid = 0 WHERE identifier = ? AND convoy_id = ?', { identifier, claim.convoy })
        return
    end

    local pay = Config.Pay[claim.tier]
    xPlayer.addAccountMoney('bank', pay.EarnPlayer)
    CompanyLog('payments', 'Worker paid', xPlayer, {{'Convoy', claim.convoy}, {'Bank credit', pay.EarnPlayer}, {'Delivered trailer count / tier', claim.tier}})
    if pay.EarnSociety > 0 then
        local account = awaitEvent('esx_addonaccount:getSharedAccount', 2000, 'society_companyjob')
        if account then
            account.addMoney(pay.EarnSociety)
            CompanyLog('payments', 'Society credited', xPlayer, {{'Convoy', claim.convoy}, {'Account', 'society_companyjob'}, {'Amount', pay.EarnSociety}})
        end
    end
    cb(true, pay.EarnPlayer)
    sweepSoon()
end)

registerCallback('companyjob:getConvois', {}, function(source, cb)
    if not isEmployee(getPlayer(source)) then cb({}) return end
    local rows = MySQL.query.await([[
        SELECT c.id AS id, COUNT(r.identifier) AS quantity
        FROM convoy_list c
        LEFT JOIN convoy_registered_list r ON r.convoy_id = c.id
        GROUP BY c.id
        ORDER BY c.id
    ]]) or {}
    local convois = {}
    for _, row in ipairs(rows) do
        convois[#convois + 1] = { name = row.id, quantity = tonumber(row.quantity) or 0, max = MAX_CONVOY_MEMBERS }
    end
    cb(convois)
end)

-- Periodic cleanup; the first pass waits so online clients can resync after a restart.
CreateThread(function()
    Wait(120000)
    while true do
        sweepConvoys()
        Wait(60000)
    end
end)

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local dropped = source
    requestTimes[dropped] = nil
    cuffs[dropped] = nil
    -- Release anyone the leaving officer had in cuffs.
    for target, cuff in pairs(cuffs) do
        if cuff.by == dropped then setCuffed(target, false) end
    end
    for identifier, run in pairs(runs) do
        if run.owner == dropped then
            deleteRunEntity(run)
            runs[identifier] = nil
        end
    end
    identifierBySource[dropped] = nil
    sweepSoon()
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, run in pairs(runs) do deleteRunEntity(run) end
end)
