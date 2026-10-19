ESX = nil
TriggerEvent('esx:getSharedObject', function(obj)
    ESX = obj
end)

local trailerPopTimestamps = {} -- Anti-Teleport tracker

if Config.MaxInService ~= -1 then
    TriggerEvent('esx_service:activateService', 'companyjob', Config.MaxInService)
end

-- REGISTER Job
TriggerEvent('esx_phone:registerNumber', 'companyjob', _U('alert_companyjob'), true, true)
TriggerEvent('esx_society:registerSociety', 'companyjob', 'Company Job', 'society_companyjob', 'society_companyjob', 'society_companyjob', { type = 'public' })

-- Helper function: Distance check between two players (Anti-Exploit)
local function IsPlayerNearTarget(source, target, maxDist)
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
local function IsPlayerNearCoords(source, coords, maxDist)
    local ped = GetPlayerPed(source)
    if not DoesEntityExist(ped) then
        return false
    end
    local playerCoords = GetEntityCoords(ped)
    local targetVec = vector3(coords.x, coords.y, coords.z)
    return #(playerCoords - targetVec) <= maxDist
end

-- Garage car
ESX.RegisterServerCallback('companyjob:storeNearbyVehicle', function(source, cb, nearbyVehicles)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        cb(false)
        return
    end

    if type(nearbyVehicles) ~= 'table' then
        cb(false)
        return
    end

    local foundPlate, foundNum

    for k, v in ipairs(nearbyVehicles) do
        local result = MySQL.Sync.fetchAll('SELECT plate FROM owned_vehicles WHERE plate = @plate AND job = @job', {
            ['@plate'] = v.plate,
            ['@job'] = 'companyjob'
        })

        if result[1] then
            foundPlate, foundNum = result[1].plate, k
            break
        end
    end
    if not foundPlate then
        cb(false)
    else
        MySQL.Async.execute('UPDATE owned_vehicles SET `stored` = true, `in_garage_type` = @garage, `put_by` = @putby WHERE plate = @plate', {
            ['@plate'] = foundPlate,
            ['@garage'] = 'companyjob',
            ['@putby'] = xPlayer.identifier
        }, function(rowsChanged)
            if rowsChanged == 0 then
                print(('companyjob: %s has exploited the garage!'):format(xPlayer.identifier))
                cb(false)
            else
                cb(true, foundNum)
            end
        end)
    end
end)

ESX.RegisterServerCallback('companyjob:buyJobVehicle', function(source, cb, vehicleProps, vType)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' or xPlayer.job.grade_name ~= 'boss' then
        print(('companyjob: %s attempted to buy a job vehicle without permission!'):format(xPlayer and xPlayer.identifier or source))
        cb(false)
        return
    end

    if type(vehicleProps) ~= 'table' or not vehicleProps.model or not vehicleProps.plate then
        cb(false)
        return
    end

    local price = getPriceFromHash(vehicleProps.model, xPlayer.job.grade_name, vType)

    if price <= 0 then
        cb(false)
    else
        if xPlayer.getMoney() >= price then
            xPlayer.removeMoney(price)

            MySQL.Async.execute('INSERT INTO owned_vehicles (owner, vehicle, plate, type, job, stored, in_garage_type, put_by) VALUES (@owner, @vehicle, @plate, @type, @job, @stored, @inGarageType, @put_by)', {
                ['@owner'] = xPlayer.identifier,
                ['@vehicle'] = json.encode(vehicleProps),
                ['@plate'] = vehicleProps.plate,
                ['@type'] = vType,
                ['@job'] = xPlayer.job.name,
                ['@stored'] = true,
                ['@inGarageType'] = 'companyjob',
                ['@put_by'] = xPlayer.identifier
            }, function(_)
                cb(true)
            end)
        else
            cb(false)
        end
    end
end)

function getPriceFromHash(hashKey, jobGrade, vType)
    if vType == 'car' then
        local vehicles = Config.AuthorizedVehicles[jobGrade] or {}
        local shared = Config.AuthorizedVehicles['Shared'] or {}

        for _, v in ipairs(vehicles) do
            if GetHashKey(v.model) == hashKey then
                return v.price
            end
        end

        for _, v in ipairs(shared) do
            if GetHashKey(v.model) == hashKey then
                return v.price
            end
        end
    end

    return 0
end

-- Company Vault & Depot
ESX.RegisterServerCallback('companyjob:getStockItems', function(source, cb, storing)
    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        cb({ items = {}, weapons = {} })
        return
    end

    if storing ~= 'society_companyjob' and storing ~= 'society_companyjob_depot' then
        print(('companyjob: %s attempted to access invalid storage %s!'):format(xPlayer.identifier, tostring(storing)))
        cb({ items = {}, weapons = {} })
        return
    end

    local weapons, items
    TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
        items = inventory.items
    end)
    TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
        weapons = store.get('weapons') or {}
    end)
    cb({
        items = items,
        weapons = weapons,
    })
end)

ESX.RegisterServerCallback('companyjob:getPlayerInventory', function(source, cb)
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
AddEventHandler('companyjob:getStockItem', function(itemType, itemName, count, storing)
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

    count = tonumber(count) or 0
    local sourceItem = xPlayer.getInventoryItem(itemName)

    if itemType == 'item_weapon' then
        TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
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
            end
        end)
    elseif itemType == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            local inventoryItem = inventory.getItem(itemName)

            if count > 0 and inventoryItem and inventoryItem.count >= count then
                if sourceItem.limit ~= -1 and (sourceItem.count + count) > sourceItem.limit then
                    TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
                else
                    inventory.removeItem(itemName, count)
                    xPlayer.addInventoryItem(itemName, count)
                    TriggerClientEvent('esx:showNotification', _source, _U('have_withdrawn', count, inventoryItem.label))
                end
            else
                TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
            end
        end)
    end
end)

RegisterServerEvent('companyjob:putStockItems')
AddEventHandler('companyjob:putStockItems', function(itemType, itemName, count, storing)
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

    count = tonumber(count) or 0
    local sourceItem = xPlayer.getInventoryItem(itemName)

    if itemType == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            local inventoryItem = inventory.getItem(itemName)

            if sourceItem and sourceItem.count >= count and count > 0 then
                xPlayer.removeInventoryItem(itemName, count)
                inventory.addItem(itemName, count)
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('have_deposited', count, inventoryItem.label))
            else
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('quantity_invalid'))
            end
        end)
    elseif itemType == 'item_weapon' then
        if xPlayer.hasWeapon(itemName) then
            TriggerEvent('esx_datastore:getSharedDataStore', storing, function(store)
                local storeWeapons = store.get('weapons') or {}

                table.insert(storeWeapons, {
                    name = itemName,
                    ammo = count
                })

                store.set('weapons', storeWeapons)
                xPlayer.removeWeapon(itemName)
            end)
        end
    end
end)

-- Menu Mobile Mafia (Secured with Job, Grade & Distance Checks)
RegisterServerEvent('companyjob:handcuff')
AddEventHandler('companyjob:handcuff', function(target)
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
AddEventHandler('companyjob:drag', function(target)
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
AddEventHandler('companyjob:putInVehicle', function(target)
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
AddEventHandler('companyjob:OutVehicle', function(target)
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
AddEventHandler('companyjob:confiscatePlayerItem', function(target, itemType, itemName, amount)
    local _source = source
    local sourceXPlayer = ESX.GetPlayerFromId(_source)
    local targetXPlayer = ESX.GetPlayerFromId(target)

    if not sourceXPlayer or not targetXPlayer or sourceXPlayer.job.name ~= 'companyjob' or (sourceXPlayer.job.grade_name ~= 'underboss' and sourceXPlayer.job.grade_name ~= 'boss') then
        print(('companyjob: %s attempted to confiscate without permission!'):format(sourceXPlayer and sourceXPlayer.identifier or _source))
        return
    end

    if not IsPlayerNearTarget(_source, target, 10.0) then
        print(('companyjob: %s attempted to confiscate from too far away!'):format(sourceXPlayer.identifier))
        return
    end

    amount = tonumber(amount) or 0

    if itemType == 'item_standard' then
        local targetItem = targetXPlayer.getInventoryItem(itemName)
        local sourceItem = sourceXPlayer.getInventoryItem(itemName)

        if targetItem and targetItem.count > 0 and targetItem.count >= amount and amount > 0 then
            if sourceItem.limit ~= -1 and (sourceItem.count + amount) > sourceItem.limit then
                TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
            else
                targetXPlayer.removeInventoryItem(itemName, amount)
                sourceXPlayer.addInventoryItem(itemName, amount)
                TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated', amount, sourceItem.label, targetXPlayer.name))
                TriggerClientEvent('esx:showNotification', target, _U('got_confiscated', amount, sourceItem.label, sourceXPlayer.name))
            end
        else
            TriggerClientEvent('esx:showNotification', _source, _U('quantity_invalid'))
        end

    elseif itemType == 'item_account' then
        local targetAccount = targetXPlayer.getAccount(itemName)
        if targetAccount and targetAccount.money >= amount and amount > 0 then
            targetXPlayer.removeAccountMoney(itemName, amount)
            sourceXPlayer.addAccountMoney(itemName, amount)

            TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_account', amount, itemName, targetXPlayer.name))
            TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_account', amount, itemName, sourceXPlayer.name))
        end

    elseif itemType == 'item_weapon' then
        if targetXPlayer.hasWeapon(itemName) then
            targetXPlayer.removeWeapon(itemName, amount)
            sourceXPlayer.addWeapon(itemName, amount)

            TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_weapon', ESX.GetWeaponLabel(itemName), targetXPlayer.name, amount))
            TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_weapon', ESX.GetWeaponLabel(itemName), amount, sourceXPlayer.name))
        end
    end
end)

ESX.RegisterServerCallback('companyjob:getOtherPlayerData', function(source, cb, target)
    local xPlayer = ESX.GetPlayerFromId(source)
    local targetXPlayer = ESX.GetPlayerFromId(target)

    if not xPlayer or not targetXPlayer or xPlayer.job.name ~= 'companyjob' or not IsPlayerNearTarget(source, target, 10.0) then
        cb({})
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
    end
end)

RegisterServerEvent('companyjob:message')
AddEventHandler('companyjob:message', function(target, msg)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)
    if xPlayer and xPlayer.job.name == 'companyjob' and IsPlayerNearTarget(_source, target, 10.0) then
        TriggerClientEvent('esx:showNotification', target, msg)
    end
end)

-- Menu convois (Secured against SQL, Teleport & Money/Item Exploits)
RegisterServerEvent('companyjob:registerConvoi')
AddEventHandler('companyjob:registerConvoi', function(idConvoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    local identifier = xPlayer.identifier
    idConvoi = tonumber(idConvoi) or 0

    -- If registering for a real convoy (> 0), verify player is near the register marker
    if idConvoi > 0 and not IsPlayerNearCoords(_source, Config.Zones.ConvoiRegister.Pos, 15.0) then
        print(('companyjob: %s attempted to register for a convoy from far away!'):format(identifier))
        return
    end

    local result = MySQL.Sync.fetchAll('SELECT * FROM `convoy_registered_list` WHERE identifier = @identifier', {
        ['@identifier'] = identifier
    })
    if result[1] then
        MySQL.Async.execute('UPDATE `convoy_registered_list` SET `convoy_id`=@idConvoi, `is_paid`=false, `is_trailer_stored`=false WHERE identifier = @identifier', {
            ['@identifier'] = identifier,
            ['@idConvoi'] = idConvoi
        })
    else
        MySQL.Async.execute('INSERT INTO `convoy_registered_list`(`identifier`, `is_trailer_stored`, `convoy_id`, `is_paid`) VALUES (@identifier, false, @idConvoi, false)', {
            ['@identifier'] = identifier,
            ['@idConvoi'] = idConvoi
        })
    end
end)

RegisterServerEvent('companyjob:unregisterConvoi')
AddEventHandler('companyjob:unregisterConvoi', function(idConvoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    local identifier = xPlayer.identifier
    local result = MySQL.Sync.fetchAll('SELECT * FROM `convoy_registered_list` WHERE identifier = @identifier AND convoy_id = @idConvoi', {
        ['@identifier'] = identifier,
        ['@idConvoi'] = idConvoi
    })
    if result[1] then
        MySQL.Async.execute('UPDATE `convoy_registered_list` SET `convoy_id`=0 WHERE identifier = @identifier', {
            ['@identifier'] = identifier
        })
    else
        TriggerClientEvent('esx:showNotification', xPlayer.source, 'You are not registered to convoy ' .. tostring(idConvoi) .. '.')
    end
end)

RegisterServerEvent('companyjob:popTrailer')
AddEventHandler('companyjob:popTrailer', function()
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    trailerPopTimestamps[xPlayer.identifier] = os.time()

    MySQL.Async.execute('UPDATE `convoy_registered_list` SET `is_trailer_stored`=false WHERE identifier = @identifier', {
        ['@identifier'] = xPlayer.identifier,
    })
end)

RegisterServerEvent('companyjob:storeTrailer')
AddEventHandler('companyjob:storeTrailer', function()
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        print(('companyjob: %s attempted to trigger storeTrailer without job!'):format(xPlayer and xPlayer.identifier or _source))
        return
    end

    local identifier = xPlayer.identifier

    -- 1. Anti-Exploit: Distance check to StoreTrailer zone
    if not IsPlayerNearCoords(_source, Config.Zones.StoreTrailer.Pos, 25.0) then
        print(('companyjob: %s attempted to store trailer from far away (Teleport/Trigger Exploit)!'):format(identifier))
        return
    end

    -- 2. Anti-Teleport: Check if player popped the trailer at least 60 seconds ago (Paleto Bay to LS Docks takes > 3 mins)
    local popTime = trailerPopTimestamps[identifier] or 0
    if (os.time() - popTime) < 60 then
        print(('companyjob: %s attempted to store trailer too fast after spawning (Teleport Hack)!'):format(identifier))
        return
    end

    -- 3. Database verification
    local check = MySQL.Sync.fetchAll('SELECT convoy_id, is_trailer_stored FROM `convoy_registered_list` WHERE identifier = @identifier', {
        ['@identifier'] = identifier
    })

    if check[1] and check[1].convoy_id > 0 and (check[1].is_trailer_stored == 0 or check[1].is_trailer_stored == false) then
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_trailer_stored`=true WHERE identifier = @identifier', {
            ['@identifier'] = identifier,
        })

        TriggerEvent('esx_addoninventory:getSharedInventory', 'society_companyjob_depot', function(inventory)
            if inventory then
                local item
                for i = 1, 50 do
                    item = math.random(1, #Config.listItems)
                    inventory.addItem(Config.listItems[item], math.random(1, 10))
                end
            end
        end)
    else
        print(('companyjob: %s attempted to exploit storeTrailer (already stored or not in convoy)!'):format(identifier))
    end
end)

RegisterServerEvent('companyjob:getPaidJob')
AddEventHandler('companyjob:getPaidJob', function(convoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)

    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        print(('companyjob: %s attempted to get paid without job!'):format(xPlayer and xPlayer.identifier or _source))
        return
    end

    local identifier = xPlayer.identifier

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

        -- Mark as paid BEFORE giving money to prevent race-condition spam
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_paid`=true WHERE identifier = @identifier', {
            ['@identifier'] = identifier,
        })

        xPlayer.addAccountMoney('bank', Config.Pay[quantity].EarnPlayer)
        TriggerEvent('esx_addonaccount:getSharedAccount', 'society_companyjob', function(tsAccount)
            if tsAccount ~= nil then
                tsAccount.addMoney(Config.Pay[quantity].EarnSociety)
            end
        end)
    else
        print(('companyjob: %s attempted to exploit getPaidJob!'):format(identifier))
    end
end)

RegisterServerEvent('companyjob:checkIfConvoyEnded')
AddEventHandler('companyjob:checkIfConvoyEnded', function(convoi)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)
    if not xPlayer or xPlayer.job.name ~= 'companyjob' then
        return
    end

    local quantityStored = MySQL.Sync.fetchScalar('SELECT count(`is_trailer_stored`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_trailer_stored` = true', {
        ['@idConvoi'] = convoi
    })
    local quantityPaid = MySQL.Sync.fetchScalar('SELECT count(`is_paid`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_paid` = true', {
        ['@idConvoi'] = convoi
    })

    if quantityPaid == quantityStored and quantityStored > 0 then
        MySQL.Async.execute('UPDATE `convoy_registered_list` SET `is_paid`=false, `is_trailer_stored`=false, `convoy_id`=0 WHERE convoy_id = @convoiId', {
            ['@convoiId'] = convoi
        })
    end
end)

ESX.RegisterServerCallback('companyjob:getConvois', function(source, cb)
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