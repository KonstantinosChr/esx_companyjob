local ESX
local JOB = 'companyjob'
local CONTROL_CONTEXT = 38 -- E

local PlayerData = {}
local state = {
    inService = false,
    convoy = 0,
    onJob = false,        -- registered in a convoy, no trailer yet
    trailerOut = false,   -- trailer issued, not delivered
    awaitingPay = false,  -- delivered, waiting to collect the payment
    requestPending = false,
}
local currentZone
local isInShopMenu, shopRestoreCoords, spawnedVehicles = false, nil, {}
local isHandcuffed = false
local drag = { active = false, officer = nil }

-- Markers that only show up while they are relevant to the current delivery step.
local dynamicMarkerTypes = { PopTrailer = 27, StoreTrailer = 27, GetPaid = 29 }

local uniformsByGrade = {
    recruit = { 'recruit_wear' },
    transporter = { 'transporter_wear' },
    underboss = { 'recruit_wear', 'transporter_wear', 'underboss_wear' },
    boss = { 'recruit_wear', 'transporter_wear', 'underboss_wear', 'boss_wear' },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function isCompanyJob()
    return PlayerData.job ~= nil and PlayerData.job.name == JOB
end

local function gradeName()
    return PlayerData.job and PlayerData.job.grade_name
end

local function isOfficerGrade()
    return gradeName() == 'underboss' or gradeName() == 'boss'
end

local function notify(message)
    ESX.ShowNotification(message)
end

local function drawLoadingText(text)
    SetTextFont(4)
    SetTextScale(0.0, 0.5)
    SetTextColour(255, 255, 255, 255)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.5, 0.5)
end

local function resetDeliveryState()
    state.convoy, state.onJob, state.trailerOut, state.awaitingPay = 0, false, false, false
end

local function syncRun(attempt)
    attempt = attempt or 1
    if not isCompanyJob() then resetDeliveryState() return end
    ESX.TriggerServerCallback('companyjob:syncRun', function(data)
        if type(data) ~= 'table' then
            -- Throttled or rejected; try again shortly.
            if attempt < 3 then SetTimeout(1500, function() syncRun(attempt + 1) end) end
            return
        end
        state.convoy = data.convoy or 0
        state.trailerOut = data.trailerOut == true
        state.awaitingPay = data.awaitingPay == true
        state.onJob = state.convoy > 0 and not state.trailerOut and not state.awaitingPay and not data.finished
    end)
end

local function onJobChanged()
    state.inService = false
    if Config.MaxInService ~= -1 and PlayerData.identifier then
        ESX.TriggerServerCallback('esx_service:isInService', function(isInService)
            if isInService then
                TriggerServerEvent('esx_service:disableService', JOB, PlayerData.identifier)
            end
        end, JOB, PlayerData.identifier)
    end
    if not isCompanyJob() and not isInShopMenu then ESX.UI.Menu.CloseAll() end
    syncRun()
end

-- ---------------------------------------------------------------------------
-- ESX initialisation
-- ---------------------------------------------------------------------------

CreateThread(function()
    local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok and obj then ESX = obj end
    while not ESX do
        TriggerEvent('esx:getSharedObject', function(shared) ESX = shared end)
        Wait(100)
    end
    while not ESX.GetPlayerData().job do Wait(100) end
    PlayerData = ESX.GetPlayerData()
    onJobChanged()
end)

RegisterNetEvent('esx:playerLoaded', function(xPlayer)
    if not ESX then return end
    PlayerData = xPlayer
    onJobChanged()
end)

RegisterNetEvent('esx:setJob', function(job)
    if not ESX then return end
    PlayerData.job = job
    onJobChanged()
end)

-- ---------------------------------------------------------------------------
-- Cloakroom & duty
-- ---------------------------------------------------------------------------

local function setUniform(uniform)
    TriggerEvent('skinchanger:getSkin', function(skin)
        local outfit = Config.Uniforms[uniform] and Config.Uniforms[uniform][skin.sex == 0 and 'male' or 'female']
        if outfit then
            TriggerEvent('skinchanger:loadClothes', skin, outfit)
        else
            notify(_U('no_outfit'))
        end
    end)
end

local function announceService(key)
    TriggerServerEvent('esx_service:notifyAllInService', {
        title = _U('service_anonunce'),
        subject = '',
        msg = _U(key, GetPlayerName(PlayerId())),
        iconType = 1
    }, JOB)
end

local function goOnDuty(uniform)
    if Config.MaxInService == -1 then
        state.inService = true
        setUniform(uniform)
        return
    end
    ESX.TriggerServerCallback('esx_service:isInService', function(isInService)
        if isInService then
            state.inService = true
            setUniform(uniform)
            return
        end
        ESX.TriggerServerCallback('esx_service:enableService', function(canTakeService, maxInService, inServiceCount)
            if not canTakeService then
                notify(_U('service_max', inServiceCount, maxInService))
                return
            end
            state.inService = true
            announceService('service_in_announce')
            notify(_U('service_in'))
            setUniform(uniform)
        end, JOB, PlayerData.identifier)
    end, JOB, PlayerData.identifier)
end

local function leaveConvoyQuietly()
    if state.convoy > 0 and not state.trailerOut and not state.awaitingPay then
        ESX.TriggerServerCallback('companyjob:leaveConvoy', function(success)
            if success then resetDeliveryState() end
        end)
    end
end

local function goOffDuty()
    ESX.TriggerServerCallback('esx_skin:getPlayerSkin', function(skin)
        TriggerEvent('skinchanger:loadSkin', skin)
    end)
    if Config.MaxInService == -1 then
        if state.inService then notify(_U('service_out')) end
        state.inService = false
        leaveConvoyQuietly()
        return
    end
    ESX.TriggerServerCallback('esx_service:isInService', function(isInService)
        state.inService = false
        if not isInService then return end
        announceService('service_out_announce')
        TriggerServerEvent('esx_service:disableService', JOB, PlayerData.identifier)
        leaveConvoyQuietly()
        notify(_U('service_out'))
    end, JOB, PlayerData.identifier)
end

local function OpenCloakroomMenu()
    local elements = { { label = _U('citizen_wear'), value = 'citizen_wear' } }
    for _, uniform in ipairs(uniformsByGrade[gradeName()] or {}) do
        elements[#elements + 1] = { label = _U('duty_wear', _U(uniform)), value = uniform }
    end

    ESX.UI.Menu.CloseAll()
    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'cloakroom_actions', {
        css = 'unknownstory',
        title = _U('cloakroom'),
        align = 'top-left',
        elements = elements
    }, function(data)
        if data.current.value == 'citizen_wear' then
            goOffDuty()
        else
            goOnDuty(data.current.value)
        end
    end, function(_, menu)
        menu.close()
    end)
end

-- ---------------------------------------------------------------------------
-- Garage & vehicle shop
-- ---------------------------------------------------------------------------

local function GetAvailableVehicleSpawnPoint()
    for _, spawnPoint in ipairs(Config.Zones.CarGarage.SpawnPoints) do
        if ESX.Game.IsSpawnPointClear(spawnPoint.coords, spawnPoint.radius) then
            return spawnPoint
        end
    end
    notify(_U('vehicle_blocked'))
end

local function DeleteSpawnedVehicles()
    for _, vehicle in ipairs(spawnedVehicles) do
        if DoesEntityExist(vehicle) then ESX.Game.DeleteVehicle(vehicle) end
    end
    spawnedVehicles = {}
end

local function WaitForVehicleToLoad(model)
    local modelHash = type(model) == 'number' and model or GetHashKey(model)
    if HasModelLoaded(modelHash) then return end
    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        Wait(0)
        DisableControlAction(0, 27, true)  -- up
        DisableControlAction(0, 173, true) -- down
        DisableControlAction(0, 174, true) -- left
        DisableControlAction(0, 175, true) -- right
        DisableControlAction(0, 176, true) -- enter
        DisableControlAction(0, 177, true) -- backspace
        drawLoadingText(_U('vehicleshop_awaiting_model'))
    end
end

local function previewVehicle(entry, shopCoords)
    local playerPed = PlayerPedId()
    DeleteSpawnedVehicles()
    WaitForVehicleToLoad(entry.model)
    ESX.Game.SpawnLocalVehicle(entry.model, shopCoords, 0.0, function(vehicle)
        spawnedVehicles[#spawnedVehicles + 1] = vehicle
        TaskWarpPedIntoVehicle(playerPed, vehicle, -1)
        FreezeEntityPosition(vehicle, true)
        if entry.livery then
            SetVehicleModKit(vehicle, 0)
            SetVehicleLivery(vehicle, entry.livery)
        end
    end)
end

local function leaveShop()
    local playerPed = PlayerPedId()
    isInShopMenu = false
    ESX.UI.Menu.CloseAll()
    DeleteSpawnedVehicles()
    FreezeEntityPosition(playerPed, false)
    SetEntityVisible(playerPed, true)
    if shopRestoreCoords then ESX.Game.Teleport(playerPed, shopRestoreCoords) end
    shopRestoreCoords = nil
end

local function OpenShopMenu(elements, restoreCoords, shopCoords)
    if #elements == 0 then notify(_U('shop_empty')) return end
    isInShopMenu = true
    shopRestoreCoords = restoreCoords

    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'vehicle_shop', {
        css = 'unknownstory',
        title = _U('vehicleshop_title'),
        align = 'top-left',
        elements = elements
    }, function(data)
        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'vehicle_shop_confirm', {
            css = 'unknownstory',
            title = _U('vehicleshop_confirm', data.current.name, data.current.price),
            align = 'top-left',
            elements = {
                { label = _U('confirm_no'), value = 'no' },
                { label = _U('confirm_yes'), value = 'yes' }
            }
        }, function(data2, menu2)
            if data2.current.value ~= 'yes' then menu2.close() return end
            local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
            local props = ESX.Game.GetVehicleProperties(vehicle)
            props.plate = exports['esx_vehicleshop']:GeneratePlate()

            ESX.TriggerServerCallback('companyjob:buyJobVehicle', function(bought)
                if bought then
                    notify(_U('vehicleshop_bought', data.current.name, ESX.Math.GroupDigits(data.current.price)))
                    leaveShop()
                else
                    notify(_U('vehicleshop_money'))
                    menu2.close()
                end
            end, props, data.current.type)
        end, function(_, menu2)
            menu2.close()
        end)
    end, function()
        leaveShop()
    end, function(data)
        previewVehicle(data.current, shopCoords)
    end)

    previewVehicle(elements[1], shopCoords)
end

local function shopElements()
    local elements = {}
    local lists = { Config.AuthorizedVehicles[gradeName()] or {}, Config.AuthorizedVehicles.Shared or {} }
    for _, list in ipairs(lists) do
        for _, vehicle in ipairs(list) do
            elements[#elements + 1] = {
                label = ('%s - <span style="color:green;">%s</span>'):format(vehicle.label, _U('shop_item', ESX.Math.GroupDigits(vehicle.price))),
                name = vehicle.label,
                model = vehicle.model,
                price = vehicle.price,
                livery = vehicle.livery,
                type = 'car'
            }
        end
    end
    return elements
end

local function StoreNearbyVehicle(playerCoords)
    local vehicles, candidates = ESX.Game.GetVehiclesInArea(playerCoords, 30.0), {}
    for _, vehicle in ipairs(vehicles) do
        if GetVehicleNumberOfPassengers(vehicle) == 0 and IsVehicleSeatFree(vehicle, -1)
            and NetworkGetEntityIsNetworked(vehicle) then
            candidates[#candidates + 1] = { netId = NetworkGetNetworkIdFromEntity(vehicle) }
        end
        if #candidates >= 32 then break end
    end
    if #candidates == 0 then notify(_U('garage_store_nearby')) return end

    -- The server validates and deletes the vehicle itself.
    ESX.TriggerServerCallback('companyjob:storeNearbyVehicle', function(stored)
        notify(stored and _U('garage_has_stored') or _U('garage_has_notstored'))
    end, candidates)
end

local function OpenJobGarage(vehicleType)
    ESX.TriggerServerCallback('esx_vehicleshop:retrieveJobVehicles', function(jobVehicles)
        if not jobVehicles or #jobVehicles == 0 then notify(_U('garage_empty')) return end
        local garage = {}
        for _, v in ipairs(jobVehicles) do
            local props = json.decode(v.vehicle)
            local label = ('%s - <span style="color:darkgoldenrod;">%s</span>: '):format(GetLabelText(GetDisplayNameFromVehicleModel(props.model)), props.plate)
            if v.stored then
                label = label .. ('<span style="color:green;">%s</span>'):format(_U('garage_stored'))
            else
                label = label .. ('<span style="color:darkred;">%s</span>'):format(_U('garage_notstored'))
            end
            garage[#garage + 1] = { label = label, stored = v.stored, model = props.model, vehicleProps = props }
        end

        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'vehicle_garage', {
            css = 'unknownstory',
            title = _U('garage_title'),
            align = 'top-left',
            elements = garage
        }, function(data, menu)
            if not data.current.stored then notify(_U('garage_notavailable')) return end
            local spawnPoint = GetAvailableVehicleSpawnPoint()
            if not spawnPoint then return end
            menu.close()
            ESX.Game.SpawnVehicle(data.current.model, spawnPoint.coords, spawnPoint.heading, function(vehicle)
                ESX.Game.SetVehicleProperties(vehicle, data.current.vehicleProps)
                TriggerServerEvent('esx_vehicleshop:setJobVehicleState', data.current.vehicleProps.plate, false)
                notify(_U('garage_released'))
            end)
        end, function(_, menu)
            menu.close()
        end)
    end, vehicleType)
end

local function OpenVehicleSpawnerMenu(vehicleType)
    local playerCoords = GetEntityCoords(PlayerPedId())
    local elements = {
        { label = _U('garage_storeditem'), action = 'garage' },
        { label = _U('garage_storeitem'), action = 'store_garage' }
    }
    if gradeName() == 'boss' then
        elements[#elements + 1] = { label = _U('garage_buyitem'), action = 'buy_vehicle' }
    end

    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'vehicle', {
        css = 'unknownstory',
        title = _U('garage_title'),
        align = 'top-left',
        elements = elements
    }, function(data)
        if data.current.action == 'buy_vehicle' then
            OpenShopMenu(shopElements(), playerCoords, Config.Zones.CarGarage.InsideShop)
        elseif data.current.action == 'garage' then
            OpenJobGarage(vehicleType)
        elseif data.current.action == 'store_garage' then
            StoreNearbyVehicle(playerCoords)
        end
    end, function(_, menu)
        menu.close()
    end)
end

-- Keep the player inside the preview vehicle.
CreateThread(function()
    while true do
        if isInShopMenu then
            DisableControlAction(0, 75, true)
            DisableControlAction(27, 75, true)
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Vault & depot
-- ---------------------------------------------------------------------------

local OpenGetStocksMenu, OpenPutStocksMenu

local function askQuantity(menuName, onValid)
    ESX.UI.Menu.Open('dialog', GetCurrentResourceName(), menuName, {
        title = _U('quantity')
    }, function(data, menu)
        local count = tonumber(data.value)
        if not count or count < 1 or count % 1 ~= 0 then
            notify(_U('quantity_invalid'))
            return
        end
        menu.close()
        onValid(count)
    end, function(_, menu)
        menu.close()
    end)
end

OpenGetStocksMenu = function(storing)
    ESX.TriggerServerCallback('companyjob:getStockItems', function(inventory)
        local elements = {}
        for _, item in ipairs(inventory.items or {}) do
            if item.count > 0 then
                elements[#elements + 1] = { label = ('x%s %s'):format(item.count, item.label), type = 'item_standard', value = item.name }
            end
        end
        for _, weapon in ipairs(inventory.weapons or {}) do
            elements[#elements + 1] = { label = ('%s [%s]'):format(ESX.GetWeaponLabel(weapon.name), weapon.ammo), type = 'item_weapon', value = weapon.name }
        end

        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'stocks_menu', {
            css = 'unknownstory',
            title = _U('companyjob_stock'),
            align = 'top-left',
            elements = elements
        }, function(data, menu)
            local itemType, itemName = data.current.type, data.current.value
            local function take(count)
                menu.close()
                ESX.TriggerServerCallback('companyjob:takeStockItem', function()
                    OpenGetStocksMenu(storing)
                end, itemType, itemName, count, storing)
            end
            if itemType == 'item_standard' then
                askQuantity('stocks_menu_get_item_count', take)
            elseif itemType == 'item_weapon' then
                take(nil)
            end
        end, function(_, menu)
            menu.close()
        end)
    end, storing)
end

OpenPutStocksMenu = function(storing)
    ESX.TriggerServerCallback('companyjob:getPlayerInventory', function(inventory)
        local elements = {}
        for _, item in ipairs(inventory.items or {}) do
            if item.count > 0 then
                elements[#elements + 1] = { label = ('%s x%s'):format(item.label, item.count), type = 'item_standard', value = item.name }
            end
        end
        for _, weapon in ipairs(inventory.weapons or {}) do
            elements[#elements + 1] = { label = ('%s [%s]'):format(weapon.label or ESX.GetWeaponLabel(weapon.name), weapon.ammo), type = 'item_weapon', value = weapon.name }
        end

        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'stocks_menu', {
            css = 'unknownstory',
            title = _U('inventory'),
            align = 'top-left',
            elements = elements
        }, function(data, menu)
            local itemType, itemName = data.current.type, data.current.value
            local function deposit(count)
                menu.close()
                ESX.TriggerServerCallback('companyjob:depositStockItem', function()
                    OpenPutStocksMenu(storing)
                end, itemType, itemName, count, storing)
            end
            if itemType == 'item_standard' then
                askQuantity('stocks_menu_put_item_count', deposit)
            elseif itemType == 'item_weapon' then
                deposit(nil)
            end
        end, function(_, menu)
            menu.close()
        end)
    end)
end

local function OpenRoomMenu(title, storing)
    ESX.UI.Menu.CloseAll()
    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'room', {
        css = 'unknownstory',
        title = title,
        align = 'top-left',
        elements = {
            { label = _U('remove_object'), value = 'room_inventory' },
            { label = _U('deposit_object'), value = 'player_inventory' }
        }
    }, function(data)
        if data.current.value == 'room_inventory' then
            OpenGetStocksMenu(storing)
        elseif data.current.value == 'player_inventory' then
            OpenPutStocksMenu(storing)
        end
    end, function(_, menu)
        menu.close()
    end)
end

local function OpenBossActionsMenu()
    ESX.UI.Menu.CloseAll()
    local elements = { { label = _U('inventory'), value = 'inventory' } }
    if gradeName() == 'boss' then
        elements[#elements + 1] = { label = _U('boss_actions'), value = 'boss_actions' }
    end

    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'companyjob', {
        css = 'unknownstory',
        title = _U('companyjob'),
        align = 'top-left',
        elements = elements
    }, function(data, menu)
        if data.current.value == 'boss_actions' then
            TriggerEvent('esx_society:openBossMenu', JOB, function(_, menu2)
                menu2.close()
            end)
        elseif data.current.value == 'inventory' then
            OpenRoomMenu(_U('companyjob'), 'society_companyjob')
        end
    end, function(_, menu)
        menu.close()
    end)
end

-- ---------------------------------------------------------------------------
-- Convoys & deliveries
-- ---------------------------------------------------------------------------

local convoyRejections = {
    full = 'convoy_full',
    unpaid = 'convoy_unpaid',
    busy = 'convoy_busy',
}

local function OpenConvoisMenu()
    ESX.TriggerServerCallback('companyjob:getConvois', function(convois)
        local elements = {
            head = { _U('convoy_head_id'), _U('convoy_head_count'), _U('convoy_head_action') },
            rows = {}
        }
        for _, convoy in ipairs(convois) do
            local actions
            if convoy.quantity >= (convoy.max or 8) and convoy.name ~= state.convoy then
                actions = '{{' .. _U('convoy_leave') .. '|unregister}}'
            else
                actions = '{{' .. _U('convoy_join') .. '|register}} {{' .. _U('convoy_leave') .. '|unregister}}'
            end
            elements.rows[#elements.rows + 1] = {
                data = convoy,
                cols = { convoy.name, ('%s/%s'):format(convoy.quantity, convoy.max or 8), actions }
            }
        end

        ESX.UI.Menu.Open('list', GetCurrentResourceName(), 'convois', elements, function(data, menu)
            local convoyId = data.data.name
            menu.close()
            if data.value == 'register' then
                ESX.TriggerServerCallback('companyjob:joinConvoy', function(success, reason)
                    if not success then
                        notify(_U(convoyRejections[reason] or 'convoy_join_rejected'))
                        return
                    end
                    state.convoy, state.onJob, state.trailerOut, state.awaitingPay = convoyId, true, false, false
                    notify(_U('convoy_joined', convoyId))
                end, convoyId)
            elseif data.value == 'unregister' then
                ESX.TriggerServerCallback('companyjob:leaveConvoy', function(success, reason)
                    if not success then
                        notify(_U(convoyRejections[reason] or 'convoy_leave_rejected'))
                        return
                    end
                    resetDeliveryState()
                    notify(_U('convoy_left'))
                end)
            end
        end, function(_, menu)
            menu.close()
        end)
    end)
end

local function CancelDelivery()
    if state.requestPending then return end
    state.requestPending = true
    ESX.TriggerServerCallback('companyjob:leaveConvoy', function(success, reason)
        state.requestPending = false
        if not success then
            notify(_U(convoyRejections[reason] or 'cancel_rejected'))
            return
        end
        resetDeliveryState()
        notify(_U('delivery_cancelled'))
    end)
end

local function PopTrailer()
    if not state.onJob or state.requestPending then return end
    state.requestPending = true
    ESX.TriggerServerCallback('companyjob:spawnTrailer', function(netId)
        state.requestPending = false
        if not netId then notify(_U('trailer_rejected')) return end
        state.onJob, state.trailerOut = false, true
        notify(_U('trailer_issued'))
    end)
end

local function StoreTrailer()
    if not state.trailerOut or state.requestPending then return end
    state.requestPending = true
    ESX.TriggerServerCallback('companyjob:deliverTrailer', function(success)
        state.requestPending = false
        if not success then notify(_U('delivery_rejected', Config.MinDeliverySeconds or 180)) return end
        state.trailerOut, state.awaitingPay = false, true
        notify(_U('delivery_done'))
    end)
end

local function GetPaid()
    if not state.awaitingPay or state.requestPending then return end
    state.requestPending = true
    ESX.TriggerServerCallback('companyjob:collectPay', function(success, amount)
        state.requestPending = false
        if not success then notify(_U('pay_rejected')) return end
        state.awaitingPay = false
        notify(_U('paid', ESX.Math.GroupDigits(amount or 0)))
    end)
end

-- ---------------------------------------------------------------------------
-- F6 actions menu
-- ---------------------------------------------------------------------------

local function OpenBodySearchMenu(player)
    local serverId = GetPlayerServerId(player)
    ESX.TriggerServerCallback('companyjob:getOtherPlayerData', function(data)
        if type(data) ~= 'table' then notify(_U('search_rejected')) return end
        local elements = {}

        for _, account in ipairs(data.accounts or {}) do
            if account.name == 'black_money' and account.money > 0 then
                elements[#elements + 1] = {
                    label = _U('confiscate_dirty', ESX.Math.Round(account.money)),
                    value = 'black_money', itemType = 'item_account', amount = account.money
                }
                break
            end
        end
        elements[#elements + 1] = { label = _U('guns_label') }
        for _, weapon in ipairs(data.weapons or {}) do
            elements[#elements + 1] = {
                label = _U('confiscate_weapon', ESX.GetWeaponLabel(weapon.name), weapon.ammo),
                value = weapon.name, itemType = 'item_weapon', amount = weapon.ammo
            }
        end
        elements[#elements + 1] = { label = _U('inventory_label') }
        for _, item in ipairs(data.inventory or {}) do
            if item.count > 0 then
                elements[#elements + 1] = {
                    label = _U('confiscate_inv', item.count, item.label),
                    value = item.name, itemType = 'item_standard', amount = item.count
                }
            end
        end

        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'body_search', {
            css = 'unknownstory',
            title = _U('search'),
            align = 'top-left',
            elements = elements,
        }, function(data1, menu)
            if not data1.current.value then return end
            menu.close()
            ESX.TriggerServerCallback('companyjob:confiscate', function()
                OpenBodySearchMenu(player)
            end, serverId, data1.current.itemType, data1.current.value, data1.current.amount)
        end, function(_, menu)
            menu.close()
        end)
    end, serverId)
end

local function closestPlayerInRange()
    local closestPlayer, closestDistance = ESX.Game.GetClosestPlayer()
    if closestPlayer ~= -1 and closestDistance <= 3.0 then return closestPlayer end
end

local function OpenBillingDialog()
    ESX.UI.Menu.Open('dialog', GetCurrentResourceName(), 'billing', {
        title = _U('invoice_amount')
    }, function(data, menu)
        local amount = tonumber(data.value)
        if not amount or amount <= 0 or amount % 1 ~= 0 then
            notify(_U('amount_invalid'))
            return
        end
        local target = closestPlayerInRange()
        if not target then notify(_U('no_players_nearby')) return end
        menu.close()
        TriggerServerEvent('esx_billing:sendBill', GetPlayerServerId(target), 'society_companyjob', _U('companyjob'), amount)
    end, function(_, menu)
        menu.close()
    end)
end

local targetActions = {
    handcuff = 'companyjob:handcuff',
    drag = 'companyjob:drag',
    put_in_vehicle = 'companyjob:putInVehicle',
    out_the_vehicle = 'companyjob:OutVehicle',
}

local function OpenMobileActionsMenu()
    local elements = { { label = _U('billing'), value = 'billing' } }
    if isOfficerGrade() then
        for _, action in ipairs({ 'handcuff', 'drag', 'put_in_vehicle', 'out_the_vehicle', 'body_search' }) do
            elements[#elements + 1] = { label = _U(action == 'body_search' and 'search' or action), value = action }
        end
    end
    if state.convoy > 0 and not state.awaitingPay then
        elements[#elements + 1] = { label = _U('cancel_delivery'), value = 'cancel_delivery' }
    end

    ESX.UI.Menu.CloseAll()
    ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'mobile_custom_actions', {
        css = 'unknownstory',
        title = _U('companyjob'),
        align = 'top-left',
        elements = elements
    }, function(data)
        local action = data.current.value
        if action == 'cancel_delivery' then CancelDelivery() return end
        if action == 'billing' then OpenBillingDialog() return end

        local target = closestPlayerInRange()
        if not target then notify(_U('no_players_nearby')) return end
        if targetActions[action] then
            TriggerServerEvent(targetActions[action], GetPlayerServerId(target))
        elseif action == 'body_search' then
            OpenBodySearchMenu(target)
        end
    end, function(_, menu)
        menu.close()
    end)
end

RegisterCommand('companyjob_actions', function()
    if not ESX or not isCompanyJob() or isHandcuffed or IsPauseMenuActive() then return end
    OpenMobileActionsMenu()
end, false)
RegisterKeyMapping('companyjob_actions', _U('keymap_actions'), 'keyboard', 'F6')

-- ---------------------------------------------------------------------------
-- Zones: markers, prompts and actions in one loop
-- ---------------------------------------------------------------------------

local zones = {}
for name, cfg in pairs(Config.Cloakrooms) do
    zones[#zones + 1] = { name = name, kind = 'Cloakroom', cfg = cfg, pos = vector3(cfg.Pos.x, cfg.Pos.y, cfg.Pos.z), prompt = 'open_cloackroom' }
end
local zonePrompts = {
    CarGarage = 'garage', BossActions = 'boss_prompt', ConvoiRegister = 'convreg_menu',
    PopTrailer = 'pop_trailer', StoreTrailer = 'store_trailer_prompt', GetPaid = 'get_paid_prompt',
    StorageDepot = 'depot_prompt',
}
for name, cfg in pairs(Config.Zones) do
    zones[#zones + 1] = { name = name, kind = name, cfg = cfg, pos = vector3(cfg.Pos.x, cfg.Pos.y, cfg.Pos.z), prompt = zonePrompts[name] or 'open_actions' }
end

local function zoneAvailable(zone)
    if zone.kind == 'Cloakroom' then return true end
    if not state.inService then return false end
    if zone.kind == 'PopTrailer' then return state.onJob end
    if zone.kind == 'StoreTrailer' then return state.trailerOut end
    if zone.kind == 'GetPaid' then return state.awaitingPay end
    if zone.kind == 'StorageDepot' then return gradeName() ~= 'recruit' end
    return true
end

local function markerType(zone)
    if zone.cfg.Type ~= -1 then return zone.cfg.Type end
    return dynamicMarkerTypes[zone.kind] or -1
end

local zoneActions = {
    Cloakroom = OpenCloakroomMenu,
    CarGarage = function() OpenVehicleSpawnerMenu('car') end,
    BossActions = OpenBossActionsMenu,
    ConvoiRegister = OpenConvoisMenu,
    PopTrailer = PopTrailer,
    StoreTrailer = StoreTrailer,
    GetPaid = GetPaid,
    StorageDepot = function() OpenRoomMenu(_U('depot_title'), 'society_companyjob_depot') end,
}

local function exitZone()
    if not isInShopMenu then ESX.UI.Menu.CloseAll() end
    currentZone = nil
end

CreateThread(function()
    local color = Config.MarkerColor
    while true do
        local sleep = 500
        if ESX and isCompanyJob() and not isHandcuffed then
            local coords = GetEntityCoords(PlayerPedId())
            local inside
            for _, zone in ipairs(zones) do
                if zoneAvailable(zone) then
                    local dist = #(coords - zone.pos)
                    if dist < Config.DrawDistance then
                        if sleep > 100 then sleep = 100 end
                        local mType = markerType(zone)
                        if mType ~= -1 then
                            sleep = 0
                            local size = zone.cfg.Size
                            DrawMarker(mType, zone.pos.x, zone.pos.y, zone.pos.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                                size.x, size.y, size.z, color.r, color.g, color.b, 100, false, true, 2, true, nil, nil, false)
                        end
                        if dist < zone.cfg.Size.x then inside = zone end
                    end
                end
            end

            if inside ~= currentZone then
                if currentZone then exitZone() end
                currentZone = inside
            end
            if currentZone then
                sleep = 0
                ESX.ShowHelpNotification(_U(currentZone.prompt))
                if IsControlJustReleased(0, CONTROL_CONTEXT) then zoneActions[currentZone.kind]() end
            end
        elseif currentZone then
            exitZone()
        end
        Wait(sleep)
    end
end)

-- Blip
CreateThread(function()
    local blip = AddBlipForCoord(Config.Blip.Pos.x, Config.Blip.Pos.y, Config.Blip.Pos.z)
    SetBlipSprite(blip, 208)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.7)
    SetBlipColour(blip, 56)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(_U('blip_name'))
    EndTextCommandSetBlipName(blip)
end)

-- ---------------------------------------------------------------------------
-- Restraints (state comes from the server)
-- ---------------------------------------------------------------------------

local function stopDrag()
    drag.active, drag.officer = false, nil
    DetachEntity(PlayerPedId(), true, false)
end

local function releaseCuffs()
    local playerPed = PlayerPedId()
    isHandcuffed = false
    stopDrag()
    ClearPedSecondaryTask(playerPed)
    SetEnableHandcuffs(playerPed, false)
    DisablePlayerFiring(PlayerId(), false)
    SetPedCanPlayGestureAnims(playerPed, true)
    FreezeEntityPosition(playerPed, false)
    DisplayRadar(true)
end

RegisterNetEvent('companyjob:handcuff', function(cuffed)
    cuffed = cuffed == true
    if cuffed == isHandcuffed then return end
    if not cuffed then releaseCuffs() return end

    local playerPed = PlayerPedId()
    isHandcuffed = true
    ESX.UI.Menu.CloseAll()
    SetEnableHandcuffs(playerPed, true)
    SetCurrentPedWeapon(playerPed, GetHashKey('WEAPON_UNARMED'), true)
    SetPedCanPlayGestureAnims(playerPed, false)
    FreezeEntityPosition(playerPed, false)
    DisplayRadar(false)
    ESX.Streaming.RequestAnimDict('mp_arresting', function()
        TaskPlayAnim(playerPed, 'mp_arresting', 'idle', 8.0, -8, -1, 49, 0.0, false, false, false)
    end)
end)

RegisterNetEvent('companyjob:drag', function(officerServerId)
    if not isHandcuffed then return end
    if drag.active then
        stopDrag()
    else
        drag.active, drag.officer = true, tonumber(officerServerId)
    end
end)

RegisterNetEvent('companyjob:putInVehicle', function()
    if not isHandcuffed then return end
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    if not IsAnyVehicleNearPoint(coords.x, coords.y, coords.z, 5.0) then return end
    local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 5.0, 0, 71)
    if not DoesEntityExist(vehicle) then return end
    for seat = GetVehicleMaxNumberOfPassengers(vehicle) - 1, 0, -1 do
        if IsVehicleSeatFree(vehicle, seat) then
            stopDrag()
            TaskWarpPedIntoVehicle(playerPed, vehicle, seat)
            return
        end
    end
end)

RegisterNetEvent('companyjob:OutVehicle', function()
    local playerPed = PlayerPedId()
    if not isHandcuffed or not IsPedSittingInAnyVehicle(playerPed) then return end
    TaskLeaveVehicle(playerPed, GetVehiclePedIsIn(playerPed, false), 16)
end)

local cuffedDisabledControls = {
    1, 2,                 -- look left/right, up/down
    24, 25, 257, 263,     -- attack, aim, attack 2, melee
    45,                   -- reload
    22,                   -- jump
    44,                   -- cover
    37,                   -- weapon wheel
    23,                   -- enter vehicle
    288, 289, 170, 167,   -- F1, F2, F3, F6
    0, 26, 73,            -- change view, look behind, cancel animation
    59, 71, 72,           -- vehicle steer / accelerate / brake
    47, 264, 140, 141, 142, 143, -- weapon and melee
    75,                   -- exit vehicle
}
local movementControls = { 30, 31, 32, 33, 34, 35 }

CreateThread(function()
    local nextAnimCheck = 0
    while true do
        if isHandcuffed then
            local playerPed = PlayerPedId()
            for _, control in ipairs(cuffedDisabledControls) do DisableControlAction(0, control, true) end
            DisableControlAction(27, 75, true)
            DisableControlAction(2, 199, true) -- pause menu
            DisableControlAction(2, 36, true)  -- stealth
            if not Config.HandcuffedCanWalk then
                for _, control in ipairs(movementControls) do DisableControlAction(0, control, true) end
            end
            DisablePlayerFiring(PlayerId(), true)

            if drag.active then
                local officerPlayer = drag.officer and GetPlayerFromServerId(drag.officer) or -1
                local officerPed = officerPlayer ~= -1 and GetPlayerPed(officerPlayer) or 0
                if officerPed == 0 or officerPed == playerPed or not DoesEntityExist(officerPed)
                    or IsPedSittingInAnyVehicle(officerPed) or IsPedDeadOrDying(officerPed, true) then
                    stopDrag()
                elseif not IsEntityAttachedToEntity(playerPed, officerPed) then
                    AttachEntityToEntity(playerPed, officerPed, 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
                end
            end

            local now = GetGameTimer()
            if now >= nextAnimCheck then
                nextAnimCheck = now + 1000
                if not IsPedInAnyVehicle(playerPed, false) and not IsEntityPlayingAnim(playerPed, 'mp_arresting', 'idle', 3) then
                    ESX.Streaming.RequestAnimDict('mp_arresting', function()
                        TaskPlayAnim(playerPed, 'mp_arresting', 'idle', 8.0, -8, -1, 49, 0.0, false, false, false)
                    end)
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if isHandcuffed then releaseCuffs() end
    if isInShopMenu then leaveShop() end
end)
