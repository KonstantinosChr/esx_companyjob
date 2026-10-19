ESX = nil
TriggerEvent('esx:getSharedObject', function(obj)
    ESX = obj
end)

local trailerPopTimestamps = {} -- Active, server-issued deliveries; lost on restart.
local function validInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value and value >= minimum
        and value <= maximum and value % 1 == 0
end
local function validName(value)
    return type(value) == 'string' and #value > 0 and #value <= 64
end
local function officer(player)
    return player and player.job.name == 'companyjob'
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
local IsPlayerNearCoords
local function storageAllowed(source, player, storing)
    if not player or player.job.name ~= 'companyjob' then return false end
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
local function registerCallback(name, handler)
    ESX.RegisterServerCallback(name, function(source, cb, ...)
        if not acceptRequest(source, name) then
            if name == 'companyjob:getOtherPlayerData' or name == 'companyjob:getPlayerInventory'
                or name == 'companyjob:getStockItems' then cb({items = {}, inventory = {}, accounts = {}, weapons = {}})
            elseif name == 'companyjob:getConvois' then cb({}) else cb(false) end
            return
        end
        handler(source, cb, ...)
    end)
end
local function registerNetworkHandler(name, handler)
    AddEventHandler(name, function(...)
        if acceptRequest(source, name) then handler(...) end
    end)
end
AddEventHandler('playerDropped', function() requestTimes[source] = nil end)

if Config.MaxInService ~= -1 then
    TriggerEvent('esx_service:activateService', 'companyjob', Config.MaxInService)
end

-- REGISTER Job
TriggerEvent('esx_phone:registerNumber', 'companyjob', _U('alert_companyjob'), true, true)
TriggerEvent('esx_society:registerSociety', 'companyjob', 'Company Job', 'society_companyjob', 'society_companyjob', 'society_companyjob', { type = 'public' })

-- Helper function: Distance check between two players (Anti-Exploit)
local function IsPlayerNearTarget(source, target, maxDist)
    if not validInteger(target, 1, 65535) or target == source
        or not ESX.GetPlayerFromId(target)
        or GetPlayerRoutingBucket(source) ~= GetPlayerRoutingBucket(target) then return false end
    local sourcePed = GetPlayerPed(source)
    local targetPed = GetPlayerPed(target)
    if not DoesEntityExist(sourcePed) or not DoesEntityExist(targetPed) then
        return false
    end
    local sourceCoords = GetEntityCoords(sourcePed)
    local targetCoords = GetEntityCoords(targetPed)
    return #(sourceCoords - targetCoords) <= maxDist
end

-- Helper function: Distance check between player and static coords (Anti-Teleport/Trigger)
IsPlayerNearCoords = function(source, coords, maxDist)
    local ped = GetPlayerPed(source)
    if not DoesEntityExist(ped) then
        return false
    end
    local playerCoords = GetEntityCoords(ped)
    local targetVec = vector3(coords.x, coords.y, coords.z)
    return #(playerCoords - targetVec) <= maxDist
end

-- Garage integration still relies on the external vehicleshop checkout handler.
local purchasePending = {}
registerCallback('companyjob:storeNearbyVehicle', function(source, cb, nearbyVehicles)
    local player = ESX.GetPlayerFromId(source)
    if not player or player.job.name ~= 'companyjob'
        or not IsPlayerNearCoords(source, Config.Zones.CarGarage.Pos, 40.0)
        or type(nearbyVehicles) ~= 'table' or #nearbyVehicles > 32 then cb(false) return end
    for index, entry in ipairs(nearbyVehicles) do
        if type(entry) == 'table' and validInteger(entry.netId, 1, 2147483647) then
            local entity = NetworkGetEntityFromNetworkId(entry.netId)
            if entity ~= 0 and DoesEntityExist(entity) and GetEntityType(entity) == 2
                and GetEntityRoutingBucket(entity) == GetPlayerRoutingBucket(source)
                and #(GetEntityCoords(entity) - GetEntityCoords(GetPlayerPed(source))) <= 35.0 then
                local plate = (GetVehicleNumberPlateText(entity) or ''):match('^%s*(.-)%s*$')
                -- Reject vehicles occupied by any connected player.
                local occupied = false
                for _, id in ipairs(GetPlayers()) do
                    if GetVehiclePedIsIn(GetPlayerPed(tonumber(id)), false) == entity then occupied = true break end
                end
                if not occupied then
                    local changed = MySQL.Sync.execute('UPDATE owned_vehicles SET stored = 1, in_garage_type = @garage, put_by = @owner WHERE plate = @plate AND job = @job AND stored = 0', {
                        ['@garage'] = 'companyjob', ['@owner'] = player.identifier,
                        ['@plate'] = plate, ['@job'] = 'companyjob'})
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

registerCallback('companyjob:buyJobVehicle', function(source, cb, props, kind)
    local player = ESX.GetPlayerFromId(source)
    if not player or player.job.name ~= 'companyjob' or player.job.grade_name ~= 'boss'
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
        if MySQL.Sync.fetchScalar('SELECT plate FROM owned_vehicles WHERE plate = @plate', {['@plate'] = props.plate}) then return false end
        if ESX.GetPlayerFromId(source) ~= player or player.getMoney() < price then return false end
        player.removeMoney(price)
        debited = true
        -- Do not persist arbitrary client upgrades or vehicle properties.
        local changed = MySQL.Sync.execute('INSERT INTO owned_vehicles (owner, vehicle, plate, type, job, stored, in_garage_type, put_by) VALUES (@owner, @vehicle, @plate, @type, @job, 1, @garage, @owner)', {
            ['@owner'] = player.identifier,
            ['@vehicle'] = json.encode({model = props.model, plate = props.plate}),
            ['@plate'] = props.plate, ['@type'] = kind,
            ['@job'] = 'companyjob', ['@garage'] = 'companyjob'})
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

function getPriceFromHash(hashKey, jobGrade, vType)
    if vType == 'car' then
        local vehicles = Config.AuthorizedVehicles[jobGrade] or {}
        local shared = Config.AuthorizedVehicles['Shared'] or {}

        for _, v in ipairs(vehicles) do
            if GetHashKey(v.model) % 4294967296 == hashKey % 4294967296 then
                return v.price
            end
        end

        for _, v in ipairs(shared) do
            if GetHashKey(v.model) % 4294967296 == hashKey % 4294967296 then
                return v.price
            end
        end
    end

    return 0
end

-- Company Vault & Depot
registerCallback('companyjob:getStockItems', function(source, cb, storing)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not storageAllowed(source, xPlayer, storing) then
        cb({items = {}, weapons = {}})
        return
    end

    local weapons, items
    TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
        items = inventory and inventory.items or {}
    end)
    TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
        weapons = store and store.get('weapons') or {}
    end)
    cb({
        items = items,
        weapons = weapons,
    })
end)

registerCallback('companyjob:getPlayerInventory', function(source, cb)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then
        cb({ items = {}, weapons = {} })
        return
    end

    cb({
        items = xPlayer.inventory,
        weapons = xPlayer.getLoadout()
    })
end)

RegisterServerEvent('companyjob:getStockItem')
registerNetworkHandler('companyjob:getStockItem', function(itemType, itemName, count, storing)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        print(('companyjob: %s attempted to take stock item without job!'):format(xPlayer and xPlayer.identifier or _source))
        return
    end

    if storing == 'society_companyjob' then
        if not IsPlayerNearCoords(_source, Config.Zones.BossActions.Pos, 15.0) then
            print(('companyjob: %s attempted to access society vault from far away!'):format(xPlayer.identifier))
            return
        end
    elseif storing == 'society_companyjob_depot' then
        if xPlayer.job.grade_name == 'recruit' or not IsPlayerNearCoords(_source, Config.Zones.StorageDepot.Pos, 15.0) then
            print(('companyjob: %s attempted unauthorized/remote access to depot!'):format(xPlayer.identifier))
            return
        end
    else
        return
    end

    if not validName(itemName) or (itemType ~= 'item_standard' and itemType ~= 'item_weapon') then return end
    if itemType == 'item_standard' and not validInteger(count, 1, 1000000) then return end
    local sourceItem = itemType == 'item_standard' and xPlayer.getInventoryItem(itemName) or nil

    if itemType == 'item_weapon' then
        if xPlayer.hasWeapon(itemName) then return end
        TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
            if not store then return end
            local storeWeapons = store.get('weapons') or {}
            local weaponName
            local ammo

            for i = 1, #storeWeapons, 1 do
                if storeWeapons[i].name == itemName then
                    weaponName = storeWeapons[i].name
                    ammo = storeWeapons[i].ammo

                    table.remove(storeWeapons, i)
                    break
                end
            end
            if weaponName then
                store.set('weapons', storeWeapons)
                xPlayer.addWeapon(weaponName, ammo)
                CompanyLog('storage', 'Weapon withdrawn', xPlayer, {{'Storage', storing}, {'Weapon', weaponName}, {'Ammo', ammo}})
            end
        end)
    elseif itemType == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            if not inventory then return end
            local inventoryItem = inventory.getItem(itemName)

            if count > 0 and inventoryItem and inventoryItem.count >= count then
                if not canCarry(xPlayer, itemName, count) then
                    TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
                else
                    inventory.removeItem(itemName, count)
                    xPlayer.addInventoryItem(itemName, count)
                    CompanyLog('storage', 'Items withdrawn', xPlayer, {{'Storage', storing}, {'Item', itemName}, {'Count', count}})
                    TriggerClientEvent('esx:showNotification', _source, _U('have_withdrawn', count, inventoryItem.label))
                end
            else
                TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
            end
        end)
    end
end)

RegisterServerEvent('companyjob:putStockItems')
registerNetworkHandler('companyjob:putStockItems', function(itemType, itemName, count, storing)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    if storing == 'society_companyjob' then
        if not IsPlayerNearCoords(_source, Config.Zones.BossActions.Pos, 15.0) then
            return
        end
    elseif storing == 'society_companyjob_depot' then
        if xPlayer.job.grade_name == 'recruit' or not IsPlayerNearCoords(_source, Config.Zones.StorageDepot.Pos, 15.0) then
            return
        end
    else
        return
    end

    if not validName(itemName) or (itemType ~= 'item_standard' and itemType ~= 'item_weapon') then return end
    if itemType == 'item_standard' and not validInteger(count, 1, 1000000) then return end
    local sourceItem = itemType == 'item_standard' and xPlayer.getInventoryItem(itemName) or nil

    if itemType == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            if not inventory then return end
            local inventoryItem = inventory.getItem(itemName)

            if sourceItem and inventoryItem and sourceItem.count >= count and count > 0 then
                xPlayer.removeInventoryItem(itemName, count)
                inventory.addItem(itemName, count)
                CompanyLog('storage', 'Items deposited', xPlayer, {{'Storage', storing}, {'Item', itemName}, {'Count', count}})
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('have_deposited', count, inventoryItem.label))
            else
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('quantity_invalid'))
            end
        end)
    elseif itemType == 'item_weapon' then
        if xPlayer.hasWeapon(itemName) then
            count = weaponAmmo(xPlayer, itemName)
            if not validInteger(count, 0, 1000000) then return end
            TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
                if not store then return end
                local storeWeapons = store.get('weapons') or {}

                table.insert(storeWeapons, {
                    name = itemName,
                    ammo = count
                })

                store.set('weapons', storeWeapons)
                xPlayer.removeWeapon(itemName)
                CompanyLog('storage', 'Weapon deposited', xPlayer, {{'Storage', storing}, {'Weapon', itemName}, {'Ammo', count}})
            end)
        end
    end
end)

-- Menu Mobile Mafia (Secured with Job, Grade & Distance Checks)
RegisterServerEvent('companyjob:handcuff')
registerNetworkHandler('companyjob:handcuff', function(target)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if xPlayer and xPlayer.job.name == 'companyjob' and (xPlayer.job.grade_name == 'underboss' or xPlayer.job.grade_name == 'boss') then
        if IsPlayerNearTarget(_source, target, 10.0) then
            TriggerClientEvent('companyjob:handcuff', target)
        else
            print(('companyjob: %s attempted to handcuff a player from too far away!'):format(xPlayer.identifier))
        end
    else
        print(('companyjob: %s attempted to handcuff a player without permission!'):format(xPlayer and xPlayer.identifier or _source))
    end
end)

RegisterServerEvent('companyjob:drag')
registerNetworkHandler('companyjob:drag', function(target)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if xPlayer and xPlayer.job.name == 'companyjob' and (xPlayer.job.grade_name == 'underboss' or xPlayer.job.grade_name == 'boss') then
        if IsPlayerNearTarget(_source, target, 10.0) then
            TriggerClientEvent('companyjob:drag', target, _source)
        end
    else
        print(('companyjob: %s attempted to drag without permission!'):format(xPlayer and xPlayer.identifier or _source))
    end
end)

RegisterServerEvent('companyjob:putInVehicle')
registerNetworkHandler('companyjob:putInVehicle', function(target)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if xPlayer and xPlayer.job.name == 'companyjob' and (xPlayer.job.grade_name == 'underboss' or xPlayer.job.grade_name == 'boss') then
        if IsPlayerNearTarget(_source, target, 10.0) then
            TriggerClientEvent('companyjob:putInVehicle', target)
        end
    else
        print(('companyjob: %s attempted to put in vehicle without permission!'):format(xPlayer and xPlayer.identifier or _source))
    end
end)

RegisterServerEvent('companyjob:OutVehicle')
registerNetworkHandler('companyjob:OutVehicle', function(target)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if xPlayer and xPlayer.job.name == 'companyjob' and (xPlayer.job.grade_name == 'underboss' or xPlayer.job.grade_name == 'boss') then
        if IsPlayerNearTarget(_source, target, 10.0) then
            TriggerClientEvent('companyjob:OutVehicle', target)
        end
    else
        print(('companyjob: %s attempted to drag out from vehicle without permission!'):format(xPlayer and xPlayer.identifier or _source))
    end
end)

RegisterServerEvent('companyjob:confiscatePlayerItem')
registerNetworkHandler('companyjob:confiscatePlayerItem', function(target, itemType, itemName, amount)
    local _source = source
    local sourceXPlayer = ESX.GetPlayerFromId(_source)
    local targetXPlayer = validInteger(target, 1, 65535) and ESX.GetPlayerFromId(target) or nil

    if not sourceXPlayer or not targetXPlayer or sourceXPlayer.job.name ~= 'companyjob' or (sourceXPlayer.job.grade_name ~= 'underboss' and sourceXPlayer.job.grade_name ~= 'boss') then
        print(('companyjob: %s attempted to confiscate without permission!'):format(sourceXPlayer and sourceXPlayer.identifier or _source))
        return
    end

    if not IsPlayerNearTarget(_source, target, 10.0) then
        print(('companyjob: %s attempted to confiscate from too far away!'):format(sourceXPlayer.identifier))
        return
    end

    if not validName(itemName) then return end
    if itemType == 'item_weapon' then
        if sourceXPlayer.hasWeapon(itemName) then return end
        amount = weaponAmmo(targetXPlayer, itemName)
        if not validInteger(amount, 0, 1000000) then return end
    elseif not validInteger(amount, 1, 1000000) then return end

    if itemType == 'item_standard' then
        local targetItem = targetXPlayer.getInventoryItem(itemName)
        local sourceItem = sourceXPlayer.getInventoryItem(itemName)

        if targetItem and targetItem.count > 0 and targetItem.count >= amount and amount > 0 then
            if not canCarry(sourceXPlayer, itemName, amount) then
                TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
            else
                targetXPlayer.removeInventoryItem(itemName, amount)
                sourceXPlayer.addInventoryItem(itemName, amount)
                CompanyLog('interactions', 'Player property confiscated', sourceXPlayer, {{'Target ID', target}, {'Type', itemType}, {'Item/account', itemName}, {'Count/ammo', amount}})
                TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated', amount, sourceItem.label, targetXPlayer.name))
                TriggerClientEvent('esx:showNotification', target, _U('got_confiscated', amount, sourceItem.label, sourceXPlayer.name))
            end
        else
            TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
        end

    elseif itemType == 'item_account' then
        if itemName ~= 'black_money' then return end
        local targetAccount = targetXPlayer.getAccount(itemName)
        if targetAccount and targetAccount.money >= amount and amount > 0 then
            targetXPlayer.removeAccountMoney(itemName, amount)
            sourceXPlayer.addAccountMoney(itemName, amount)
                CompanyLog('interactions', 'Player property confiscated', sourceXPlayer, {{'Target ID', target}, {'Type', itemType}, {'Item/account', itemName}, {'Count/ammo', amount}})

            TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_account', amount, itemName, targetXPlayer.name))
            TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_account', amount, itemName, sourceXPlayer.name))
        end

    elseif itemType == 'item_weapon' then
        if targetXPlayer.hasWeapon(itemName) then
            targetXPlayer.removeWeapon(itemName, amount)
            sourceXPlayer.addWeapon(itemName, amount)
                CompanyLog('interactions', 'Player property confiscated', sourceXPlayer, {{'Target ID', target}, {'Type', itemType}, {'Item/account', itemName}, {'Count/ammo', amount}})

            TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_weapon', ESX.GetWeaponLabel(itemName), targetXPlayer.name, amount))
            TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_weapon', ESX.GetWeaponLabel(itemName), amount, sourceXPlayer.name))
        end
    end
end)

registerCallback('companyjob:getOtherPlayerData', function(source, cb, target)
    local xPlayer = ESX.GetPlayerFromId(source)
    local targetXPlayer = validInteger(target, 1, 65535) and ESX.GetPlayerFromId(target) or nil

    if not officer(xPlayer) or not targetXPlayer or not IsPlayerNearTarget(source, target, 10.0) then
        cb({ inventory = {}, accounts = {}, weapons = {} })
        return
    end

    if Config.EnableESXIdentity then
        local result = MySQL.Sync.fetchAll('SELECT firstname, lastname, sex, dateofbirth, height FROM users WHERE identifier = @identifier', {
            ['@identifier'] = targetXPlayer.identifier
        })

        local firstname = result[1] and result[1].firstname or 'Unknown'
        local lastname = result[1] and result[1].lastname or 'Unknown'
        local sex = result[1] and result[1].sex or 'Unknown'
        local dob = result[1] and result[1].dateofbirth or 'Unknown'
        local height = result[1] and result[1].height or 'Unknown'

        local data = {
            name = GetPlayerName(target),
            job = targetXPlayer.job,
            inventory = targetXPlayer.inventory,
            accounts = targetXPlayer.accounts,
            weapons = targetXPlayer.loadout,
            firstname = firstname,
            lastname = lastname,
            sex = sex,
            dob = dob,
            height = height
        }

        TriggerEvent('esx_status:getStatus', target, 'drunk', function(status)
            if status ~= nil then
                data.drunk = math.floor(status.percent)
            end
        end)

        if Config.EnableLicenses then
            TriggerEvent('esx_license:getLicenses', target, function(licenses)
                data.licenses = licenses
                cb(data)
            end)
        else
            cb(data)
        end
    else
        cb({name = GetPlayerName(target), job = targetXPlayer.job,
            inventory = targetXPlayer.inventory, accounts = targetXPlayer.accounts,
            weapons = targetXPlayer.getLoadout()})
    end
end)

RegisterServerEvent('companyjob:message')
registerNetworkHandler('companyjob:message', function(target, msg)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)
    if officer(xPlayer) and IsPlayerNearTarget(_source, target, 10.0) then
        TriggerClientEvent('esx:showNotification', target, _U('being_searched'))
    end
end)

-- Convoy registration and reward validation
local registrationBusy = false
local function registerConvoy(source, id)
    local player = ESX.GetPlayerFromId(source)
    if not player or player.job.name ~= 'companyjob' or registrationBusy
        or not validInteger(id, 0, 2147483647) then return false end
    local run = trailerPopTimestamps[player.identifier]
    if run and run.phase ~= 'paid' then return false end
    if id > 0 and not IsPlayerNearCoords(source, Config.Zones.ConvoiRegister.Pos, 15.0) then return false end
    registrationBusy = true -- serialize register/cancel/reset across database yields
    local ok, result = pcall(function()
        if id > 0 then
            if not MySQL.Sync.fetchScalar('SELECT id FROM convoy_list WHERE id = @id', {['@id'] = id}) then return false end
            local count = MySQL.Sync.fetchScalar('SELECT COUNT(*) FROM convoy_registered_list WHERE convoy_id = @id AND identifier <> @owner', {['@id'] = id, ['@owner'] = player.identifier})
            if tonumber(count) >= 8 then return false end
        end
        if ESX.GetPlayerFromId(source) ~= player then return false end
        -- Reserve while upsert yields, blocking trailer requests against stale registration.
        trailerPopTimestamps[player.identifier] = {phase = 'registering', owner = source}
        MySQL.Sync.execute('INSERT INTO convoy_registered_list (identifier, convoy_id, is_paid, is_trailer_stored) VALUES (@owner, @id, 0, 0) ON DUPLICATE KEY UPDATE convoy_id = @id, is_paid = 0, is_trailer_stored = 0', {
            ['@owner'] = player.identifier, ['@id'] = id})
        trailerPopTimestamps[player.identifier] = nil
        return true
    end)
    registrationBusy = false
    if not ok then trailerPopTimestamps[player.identifier] = run end
    if ok and result then CompanyLog('deliveries', id > 0 and 'Convoy joined' or 'Convoy registration cleared', player, {{'Convoy', id}}) end
    return ok and result
end
RegisterServerEvent('companyjob:registerConvoi')
registerNetworkHandler('companyjob:registerConvoi', function(id) registerConvoy(source, id) end)
registerCallback('companyjob:joinConvoy', function(source, cb, id) cb(registerConvoy(source, id)) end)
RegisterServerEvent('companyjob:unregisterConvoi')
registerNetworkHandler('companyjob:unregisterConvoi', function(id)
    if validInteger(id, 1, 2147483647) then registerConvoy(source, 0) end
end)

-- Spawn on the server: a client cannot nominate an arbitrary trailer for a reward.
registerCallback('companyjob:spawnTrailer', function(source, cb)
    local player = ESX.GetPlayerFromId(source)
    if not player or player.job.name ~= 'companyjob'
        or GetPlayerRoutingBucket(source) ~= 0
        or not IsPlayerNearCoords(source, Config.Zones.PopTrailer.Pos, 25.0)
        or trailerPopTimestamps[player.identifier] then cb(false) return end
    local run = {phase = 'spawning', owner = source}
    trailerPopTimestamps[player.identifier] = run -- reserve before database yield
    local row = MySQL.Sync.fetchAll('SELECT convoy_id, is_trailer_stored, is_paid FROM convoy_registered_list WHERE identifier = @id', {['@id'] = player.identifier})[1]
    if not row or row.convoy_id <= 0 or row.is_trailer_stored == 1 or row.is_trailer_stored == true
        or ESX.GetPlayerFromId(source) ~= player then
        trailerPopTimestamps[player.identifier] = nil
        cb(false) return
    end
    local pos = Config.Trailer.Pos
    local entity = CreateVehicle(GetHashKey(Config.Trailer.Name), pos.x, pos.y, pos.z, Config.Trailer.Heading, true, true)
    local deadline = GetGameTimer() + 5000
    while not DoesEntityExist(entity) and GetGameTimer() < deadline do Wait(50) end
    if not DoesEntityExist(entity) or ESX.GetPlayerFromId(source) ~= player then
        if DoesEntityExist(entity) then DeleteEntity(entity) end
        trailerPopTimestamps[player.identifier] = nil
        cb(false) return
    end
    run.entity, run.started, run.convoy, run.phase = entity, os.time(), row.convoy_id, 'active'
    CompanyLog('deliveries', 'Trailer issued', player, {{'Convoy', run.convoy}, {'Network ID', NetworkGetNetworkIdFromEntity(entity)}})
    cb(NetworkGetNetworkIdFromEntity(entity))
end)

registerCallback('companyjob:deliverTrailer', function(source, cb)
    local player = ESX.GetPlayerFromId(source)
    local run = player and trailerPopTimestamps[player.identifier]
    if not player or player.job.name ~= 'companyjob' or not run or run.owner ~= source
        or run.phase ~= 'active' or os.time() - run.started < 180
        or GetPlayerRoutingBucket(source) ~= 0
        or not IsPlayerNearCoords(source, Config.Zones.StoreTrailer.Pos, 25.0)
        or not DoesEntityExist(run.entity)
        or GetEntityModel(run.entity) ~= GetHashKey(Config.Trailer.Name)
        or #(GetEntityCoords(run.entity) - vector3(Config.Zones.StoreTrailer.Pos.x, Config.Zones.StoreTrailer.Pos.y, Config.Zones.StoreTrailer.Pos.z)) > 25.0
        then cb(false) return end
    run.phase = 'delivering' -- block concurrent delivery requests before yielding
    local changed = MySQL.Sync.execute('UPDATE convoy_registered_list SET is_trailer_stored = 1 WHERE identifier = @id AND convoy_id = @convoy AND is_trailer_stored = 0 AND is_paid = 0', {
        ['@id'] = player.identifier, ['@convoy'] = run.convoy})
    if changed ~= 1 then run.phase = 'active' cb(false) return end
    DeleteEntity(run.entity)
    run.entity, run.phase = nil, 'delivered'
    TriggerEvent('esx_addoninventory:getSharedInventory', 'society_companyjob_depot', function(inventory)
        if inventory and #Config.listItems > 0 then
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
                local fields = {{'Convoy', run.convoy}, {'Storage', 'society_companyjob_depot'}}
                for index = first, math.min(first + 9, #names) do
                    fields[#fields + 1] = {names[index], totals[names[index]]}
                end
                CompanyLog('deliveries', 'Delivery depot rewards', player, fields)
            end
        end
    end)
    CompanyLog('deliveries', 'Trailer delivered', player, {{'Convoy', run.convoy}, {'Trip seconds', os.time() - run.started}})
    cb(true)
end)

AddEventHandler('playerDropped', function()
    local dropped = source
    for identifier, run in pairs(trailerPopTimestamps) do
        if run.owner == dropped then
            if run.entity and DoesEntityExist(run.entity) then DeleteEntity(run.entity) end
            trailerPopTimestamps[identifier] = nil
        end
    end
end)
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, run in pairs(trailerPopTimestamps) do
        if run.entity and DoesEntityExist(run.entity) then DeleteEntity(run.entity) end
    end
end)

RegisterServerEvent('companyjob:getPaidJob')
registerNetworkHandler('companyjob:getPaidJob', function(convoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        print(('companyjob: %s attempted to get paid without job!'):format(xPlayer and xPlayer.identifier or _source))
        return
    end

    local identifier = xPlayer.identifier
    local run = trailerPopTimestamps[identifier]
    if not validInteger(convoi, 1, 2147483647) or not run or run.owner ~= _source
        or run.convoy ~= convoi or run.phase ~= 'delivered' then return end

    -- 1. Anti-Exploit: Distance check to GetPaid zone
    if not IsPlayerNearCoords(_source, Config.Zones.GetPaid.Pos, 20.0) then
        print(('companyjob: %s attempted to get paid from far away!'):format(identifier))
        return
    end

    -- 2. Database verification
    local check = MySQL.Sync.fetchAll('SELECT is_trailer_stored, is_paid, convoy_id FROM `convoy_registered_list` WHERE identifier = @identifier AND convoy_id = @idConvoi', {
        ['@identifier'] = identifier,
        ['@idConvoi'] = convoi
    })

    if check[1] and (check[1].is_trailer_stored == 1 or check[1].is_trailer_stored == true) and (check[1].is_paid == 0 or check[1].is_paid == false) then
        local quantity = MySQL.Sync.fetchScalar('SELECT count(`is_trailer_stored`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_trailer_stored` = true', {
            ['@idConvoi'] = convoi
        })

        quantity = tonumber(quantity) or 1
        if quantity < 1 then quantity = 1 end
        if quantity > #Config.Pay then quantity = #Config.Pay end

        -- Conditional claim plus memory state prevents concurrent payout requests.
        run.phase = 'paying'
        local changed = MySQL.Sync.execute('UPDATE convoy_registered_list SET is_paid = 1 WHERE identifier = @identifier AND convoy_id = @convoy AND is_paid = 0 AND is_trailer_stored = 1', {
            ['@identifier'] = identifier, ['@convoy'] = convoi
        })
        if changed ~= 1 then run.phase = 'delivered' return end
        run.phase = 'paid'
        if ESX.GetPlayerFromId(_source) ~= xPlayer then return end

        xPlayer.addAccountMoney('bank', Config.Pay[quantity].EarnPlayer)
        CompanyLog('payments', 'Worker paid', xPlayer, {{'Convoy', convoi}, {'Bank credit', Config.Pay[quantity].EarnPlayer}, {'Delivered trailer count / tier', quantity}})
        TriggerEvent('esx_addonaccount:getSharedAccount', 'society_companyjob', function(tsAccount)
            if tsAccount ~= nil then
                tsAccount.addMoney(Config.Pay[quantity].EarnSociety)
                if Config.Pay[quantity].EarnSociety > 0 then
                    CompanyLog('payments', 'Society credited', xPlayer, {{'Convoy', convoi}, {'Account', 'society_companyjob'}, {'Amount', Config.Pay[quantity].EarnSociety}})
                end
            end
        end)
    else
        print(('companyjob: %s attempted to exploit getPaidJob!'):format(identifier))
    end
end)

RegisterServerEvent('companyjob:checkIfConvoyEnded')
registerNetworkHandler('companyjob:checkIfConvoyEnded', function(convoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    local run = trailerPopTimestamps[xPlayer.identifier]
    if not validInteger(convoi, 1, 2147483647) or not run or run.convoy ~= convoi or run.phase ~= 'paid' then return end
    local quantityStored = MySQL.Sync.fetchScalar('SELECT count(`is_trailer_stored`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi ', {
        ['@idConvoi'] = convoi
    })
    local quantityPaid = MySQL.Sync.fetchScalar('SELECT count(`is_paid`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_paid` = true', {
        ['@idConvoi'] = convoi
    })

    if tonumber(quantityPaid) == tonumber(quantityStored) and tonumber(quantityStored) > 0 and not registrationBusy then
        registrationBusy = true
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_paid`=false, `is_trailer_stored`=false, `convoy_id`=0 WHERE convoy_id = @convoiId AND is_paid = true', {
            ['@convoiId'] = convoi
        })
        registrationBusy = false
    end
end)

registerCallback('companyjob:getConvois', function(source, cb)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        cb({})
        return
    end

    local convois = {}
    local result = MySQL.Sync.fetchAll('SELECT * FROM `convoy_list`')
    if result[1] and #result > 0 then
        for _, v in pairs(result) do
            local name = v.id
            local quantity = MySQL.Sync.fetchScalar('SELECT count(`convoy_id`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi', {
                ['@idConvoi'] = name
            })
            table.insert(convois, { name = name, quantity = quantity })
        end
    end
    cb(convois)
end)