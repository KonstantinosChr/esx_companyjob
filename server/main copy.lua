ESX = nil
TriggerEvent('esx:getSharedObject', function(obj)
    ESX = obj
end)

--
--
--

if Config.MaxInService ~= -1 then
    TriggerEvent('esx_service:activateService', 'companyjob', Config.MaxInService)
end

-- REGISTER Job
TriggerEvent('esx_phone:registerNumber', 'companyjob', _U('alert_companyjob'), true, true)
TriggerEvent('esx_society:registerSociety', 'companyjob', 'The Gold Leaf', 'society_companyjob', 'society_companyjob', 'society_companyjob', { type = 'public' })


-- Garage car
ESX.RegisterServerCallback('companyjob:storeNearbyVehicle', function(source, cb, nearbyVehicles)
    local xPlayer = ESX.GetPlayerFromId(source)
    local foundPlate, foundNum

    for k, v in ipairs(nearbyVehicles) do
        local result = MySQL.Sync.fetchAll('SELECT plate FROM owned_vehicles WHERE plate = @plate', {
            ['@plate'] = v.plate,
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


ESX.RegisterServerCallback('companyjob:buyJobVehicle', function(source, cb, vehicleProps, type)
    local xPlayer = ESX.GetPlayerFromId(source)
    local price = getPriceFromHash(vehicleProps.model, xPlayer.job.grade_name, type)

    -- vehicle model not found
    if price <= 0 then
        cb(false)
    else
        if xPlayer.getMoney() >= price then
            xPlayer.removeMoney(price)

            MySQL.Async.execute('INSERT INTO owned_vehicles (owner, vehicle, plate, type, job, stored, in_garage_type, put_by) VALUES (@owner, @vehicle, @plate, @type, @job, @stored, @inGarageType, @put_by)', {
                ['@owner'] = xPlayer.identifier,
                ['@vehicle'] = json.encode(vehicleProps),
                ['@plate'] = vehicleProps.plate,
                ['@type'] = type,
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


function getPriceFromHash(hashKey, jobGrade, type)
    if type == 'car' then
        local vehicles = Config.AuthorizedVehicles[jobGrade]
        local shared = Config.AuthorizedVehicles['Shared']

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


-- Coffre d'entreprise
ESX.RegisterServerCallback('companyjob:getStockItems', function(source, cb, storing)
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
    local items = xPlayer.inventory

    cb({
        items = items,
        weapons = xPlayer.getLoadout()
    })
end)

RegisterServerEvent('companyjob:getStockItem')
AddEventHandler('companyjob:getStockItem', function(type, itemName, count, storing)
    local _source = source
    local xPlayer = ESX.GetPlayerFromId(_source)
    local sourceItem = xPlayer.getInventoryItem(itemName)

    if type == 'item_weapon' then
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
            store.set('weapons', storeWeapons)
            xPlayer.addWeapon(weaponName, ammo)
        end)
    elseif type == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            local inventoryItem = inventory.getItem(itemName)

            -- is there enough in the society?
            if count > 0 and inventoryItem.count >= count then
                -- can the player carry the said amount of x item?
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
AddEventHandler('companyjob:putStockItems', function(type, itemName, count, storing)
    local xPlayer = ESX.GetPlayerFromId(source)
    local sourceItem = xPlayer.getInventoryItem(itemName)

    if type == 'item_standard' then
        TriggerEvent('esx_addoninventory:getSharedInventory', storing, function(inventory)
            local inventoryItem = inventory.getItem(itemName)

            -- does the player have enough of the item?
            if sourceItem.count >= count and count > 0 then
                xPlayer.removeInventoryItem(itemName, count)
                inventory.addItem(itemName, count)
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('have_deposited', count, inventoryItem.label))
            else
                TriggerClientEvent('esx:showNotification', xPlayer.source, _U('quantity_invalid'))
            end
        end)
    elseif type == 'item_weapon' then

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
end)


-- Menu Mobile Mafia
RegisterServerEvent('companyjob:handcuff')
AddEventHandler('companyjob:handcuff', function(target)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer.job.name == 'companyjob' then
        TriggerClientEvent('companyjob:handcuff', target)
    else
        print(('companyjob: %s attempted to handcuff a player (not cop)!'):format(xPlayer.identifier))
    end
end)


RegisterServerEvent('companyjob:drag')
AddEventHandler('companyjob:drag', function(target)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer.job.name == 'companyjob' then
        TriggerClientEvent('companyjob:drag', target, source)
    else
        print(('companyjob: %s attempted to drag (not cop)!'):format(xPlayer.identifier))
    end
end)


RegisterServerEvent('companyjob:putInVehicle')
AddEventHandler('companyjob:putInVehicle', function(target)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer.job.name == 'companyjob' then
        TriggerClientEvent('companyjob:putInVehicle', target)
    else
        print(('companyjob: %s attempted to put in vehicle (not cop)!'):format(xPlayer.identifier))
    end
end)


RegisterServerEvent('companyjob:OutVehicle')
AddEventHandler('companyjob:OutVehicle', function(target)
    local xPlayer = ESX.GetPlayerFromId(source)

    if xPlayer.job.name == 'companyjob' then
        TriggerClientEvent('companyjob:OutVehicle', target)
    else
        print(('companyjob: %s attempted to drag out from vehicle (not cop)!'):format(xPlayer.identifier))
    end
end)


RegisterServerEvent('companyjob:confiscatePlayerItem')
AddEventHandler('companyjob:confiscatePlayerItem', function(target, itemType, itemName, amount)
    local _source = source
    local sourceXPlayer = ESX.GetPlayerFromId(_source)
    local targetXPlayer = ESX.GetPlayerFromId(target)

    if sourceXPlayer.job.name ~= 'companyjob' then
        print(('companyjob: %s attempted to confiscate!'):format(xPlayer.identifier))
        return
    end

    if itemType == 'item_standard' then
        local targetItem = targetXPlayer.getInventoryItem(itemName)
        local sourceItem = sourceXPlayer.getInventoryItem(itemName)

        -- does the target player have enough in their inventory?
        if targetItem.count > 0 and targetItem.count <= amount then

            -- can the player carry the said amount of x item?
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
        targetXPlayer.removeAccountMoney(itemName, amount)
        sourceXPlayer.addAccountMoney(itemName, amount)

        TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_account', amount, itemName, targetXPlayer.name))
        TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_account', amount, itemName, sourceXPlayer.name))

    elseif itemType == 'item_weapon' then
        if amount == nil then
            amount = 0
        end
        targetXPlayer.removeWeapon(itemName, amount)
        sourceXPlayer.addWeapon(itemName, amount)

        TriggerClientEvent('esx:showNotification', _source, _U('you_confiscated_weapon', ESX.GetWeaponLabel(itemName), targetXPlayer.name, amount))
        TriggerClientEvent('esx:showNotification', target, _U('got_confiscated_weapon', ESX.GetWeaponLabel(itemName), amount, sourceXPlayer.name))
    end
end)


ESX.RegisterServerCallback('companyjob:getOtherPlayerData', function(source, cb, target)
    if Config.EnableESXIdentity then
        local xPlayer = ESX.GetPlayerFromId(target)
        local result = MySQL.Sync.fetchAll('SELECT firstname, lastname, sex, dateofbirth, height FROM users WHERE identifier = @identifier', {
            ['@identifier'] = xPlayer.identifier
        })

        local firstname = result[1].firstname
        local lastname = result[1].lastname
        local sex = result[1].sex
        local dob = result[1].dateofbirth
        local height = result[1].height
        local data = {
            name = GetPlayerName(target),
            job = xPlayer.job,
            inventory = xPlayer.inventory,
            accounts = xPlayer.accounts,
            weapons = xPlayer.loadout,
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
    TriggerClientEvent('esx:showNotification', target, msg)
end)


-- Menu convois
RegisterServerEvent('companyjob:registerConvoi')
AddEventHandler('companyjob:registerConvoi', function(identifier, idConvoi)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)

    local result = MySQL.Sync.fetchAll('SELECT * FROM `convoy_registered_list` WHERE identifier = @identifier', {
        ['@identifier'] = identifier })
    if result[1] then
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `convoy_id`=@idConvoi WHERE identifier = @identifier', {
            ['@identifier'] = identifier,
            ['@idConvoi'] = idConvoi
        }, function(rowsChanged)
            if rowsChanged == 0 then
                print(xPlayer.source)
                print('Registration for convoy ' .. idConvoi .. ' failed.')
            else
                print(xPlayer.source)
                print('Registered to convoy ' .. idConvoi .. '.')
            end
        end)
    else
        MySQL.Async.execute('INSERT INTO `convoy_registered_list`(`identifier`, `is_trailer_stored`, `convoy_id`) VALUES (@identifier, false, @idConvoi)', {
            ['@identifier'] = identifier,
            ['@idConvoi'] = idConvoi
        }, function(_)
            print(xPlayer.source)
            print('Registered to convoy ' .. idConvoi .. '.')
        end)
    end
end)


RegisterServerEvent('companyjob:unregisterConvoi')
AddEventHandler('companyjob:unregisterConvoi', function(identifier, idConvoi)
    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)

    local result = MySQL.Sync.fetchAll('SELECT * FROM `convoy_registered_list` WHERE identifier = @identifier AND convoy_id = @idConvoi', {
        ['@identifier'] = identifier,
        ['@idConvoi'] = idConvoi
    })
    if result[1] then
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `convoy_id`=@idConvoi WHERE identifier = @identifier', {
            ['@identifier'] = identifier,
            ['@idConvoi'] = 0
        }, function(rowsChanged)
            if rowsChanged == 0 then
                print(xPlayer.source)
                print('Unregistration from convoy ' .. idConvoi .. ' failed.')
            else
                print(xPlayer.source)
                print('Unregistered from convoy ' .. idConvoi .. '.')
            end
        end)
    else
        TriggerClientEvent('esx:showNotification', xPlayer.source, 'You are not registered to convoy ' .. idConvoi .. '.')
    end
end)


RegisterServerEvent('companyjob:storeTrailer')
AddEventHandler('companyjob:storeTrailer', function(identifier)
    MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_trailer_stored`=true WHERE identifier = @identifier', {
        ['@identifier'] = identifier,
    }, function(rowsChanged)
        if rowsChanged == 0 then
            print('Problem occurred while storing the trailer.')
        end
    end)

    TriggerEvent('esx_addoninventory:getSharedInventory', 'society_companyjob_depot', function(inventory)
        local item
        for i = 1, 50 do
            item = math.random(1, #Config.listItems)
            inventory.addItem(Config.listItems[item], math.random(1, 10))
        end
    end)
end)


RegisterServerEvent('companyjob:popTrailer')
AddEventHandler('companyjob:popTrailer', function(identifier)
    MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_trailer_stored`=false WHERE identifier = @identifier', {
        ['@identifier'] = identifier,
    }, function(rowsChanged)
        if rowsChanged == 0 then
            print('Problem getting the trailer out.')
        end
    end)
end)


RegisterServerEvent('companyjob:getPaidJob')
AddEventHandler('companyjob:getPaidJob', function(identifier, convoi)
    local quantity = MySQL.Sync.fetchScalar('SELECT count(`is_trailer_stored`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_trailer_stored` = true', {
        ['@idConvoi'] = convoi
    })

    local xPlayer = ESX.GetPlayerFromIdentifier(identifier)
    xPlayer.addAccountMoney('bank', Config.Pay[quantity].EarnPlayer)
    TriggerEvent('esx_addonaccount:getSharedAccount', 'society_companyjob', function(tsAccount)

        if tsAccount ~= nil then
            tsAccount.addMoney(Config.Pay[quantity].EarnSociety)
        end
    end)
    MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_paid`=true WHERE identifier = @identifier', {
        ['@identifier'] = identifier,
    }, function(rowsChanged)
    end)
end)


RegisterServerEvent('companyjob:checkIfConvoyEnded')
AddEventHandler('companyjob:checkIfConvoyEnded', function(convoi)
    local quantityStored = MySQL.Sync.fetchScalar('SELECT count(`is_trailer_stored`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_trailer_stored` = true', {
        ['@idConvoi'] = convoi
    })
    local quantityPaid = MySQL.Sync.fetchScalar('SELECT count(`is_paid`) FROM `convoy_registered_list` WHERE `convoy_id` = @idConvoi AND `is_paid` = true', {
        ['@idConvoi'] = convoi
    })

    if quantityPaid == quantityStored then
        MySQL.Sync.execute('UPDATE `convoy_registered_list` SET `is_paid`=false, `is_trailer_stored`=false, `convoy_id`=0 WHERE convoy_id = @convoiId', { ['@convoiId'] = convoi }, function(rowsChanged)
        end)
    end
end)


ESX.RegisterServerCallback('companyjob:getConvois', function(source, cb)
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
