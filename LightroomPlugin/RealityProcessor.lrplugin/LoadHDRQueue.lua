local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrDate = import 'LrDate'

local function homeDir()
    return '/Users/vojtechboura'
end

local function supportFolder()
    return LrPathUtils.child(
        LrPathUtils.child(
            LrPathUtils.child(homeDir(), 'Library'),
            'Application Support'
        ),
        'RealityProcessor'
    )
end

local function manifestPath()
    return LrPathUtils.child(supportFolder(), 'pending_hdr.lua')
end

local function triggerPath()
    return LrPathUtils.child(supportFolder(), 'pending_hdr.trigger')
end

local function ackPath()
    return LrPathUtils.child(supportFolder(), 'pending_hdr.ack')
end

local function heartbeatPath()
    return LrPathUtils.child(supportFolder(), 'lightroom_bridge.heartbeat')
end

local function writeFile(path, text)
    local handle = io.open(path, 'w')
    if handle then
        handle:write(text or '')
        handle:close()
        return true
    end
    return false
end

local function writeHeartbeat(text)
    writeFile(heartbeatPath(), text or 'alive')
end

local function writeAck(text)
    writeFile(ackPath(), text or 'OK')
end

local function loadManifest(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, err
    end

    local ok, manifest = pcall(chunk)
    if not ok then
        return nil, manifest
    end

    return manifest, nil
end

local function uniquePhotosFromGroups(groups)
    local result = {}
    local seen = {}

    for _, group in ipairs(groups or {}) do
        for _, photo in ipairs(group.photos or {}) do
            local id = photo.localIdentifier
            if id and not seen[id] then
                seen[id] = true
                table.insert(result, photo)
            end
        end
    end

    return result
end

local function selectGroup(catalog, photos)
    if not photos or #photos == 0 then
        return false
    end

    local active = photos[1]
    local others = {}
    for i = 2, #photos do
        table.insert(others, photos[i])
    end

    catalog:setSelectedPhotos(active, others)
    return true
end

local function runHeadlessHDRMerge()
    -- Lightroom Classic má na macOS pro headless HDR merge zkratku Control+Shift+H.
    -- SDK samotné nemá API, kterým by šlo HDR merge spustit přímo, takže použijeme
    -- systémovou klávesovou událost přes osascript/System Events.
    local command = [[/usr/bin/osascript \
-e 'tell application "Adobe Lightroom Classic" to activate' \
-e 'delay 0.4' \
-e 'tell application "System Events" to keystroke "h" using {control down, shift down}' \
>/tmp/realityprocessor_hdr_osascript.log 2>&1]]

    return LrTasks.execute(command)
end

local function waitForNewCatalogPhoto(catalog, beforeIds, timeoutSeconds, groupIndex, groupCount)
    local deadline = LrDate.currentTime() + timeoutSeconds

    while LrDate.currentTime() < deadline do
        local allPhotos = catalog:getAllPhotos()
        local newPhotos = {}

        for _, photo in ipairs(allPhotos) do
            local id = photo.localIdentifier
            if id and not beforeIds[id] then
                table.insert(newPhotos, photo)
            end
        end

        if #newPhotos > 0 then
            return newPhotos
        end

        writeHeartbeat('hdr-merging:' .. tostring(groupIndex) .. '/' .. tostring(groupCount))
        LrTasks.sleep(0.5)
    end

    return nil
end

local function processQueue(showDialog)
    writeHeartbeat('loading-manifest')

    local manifest, err = loadManifest(manifestPath())
    if not manifest then
        writeAck('ERROR: ' .. tostring(err))
        writeHeartbeat('manifest-error:' .. tostring(err))
        if showDialog then
            LrDialogs.message('Reality Processor', 'HDR frontu se nepodařilo načíst.\n\n' .. tostring(err), 'critical')
        end
        return false
    end

    if not manifest.groups or #manifest.groups == 0 then
        writeAck('ERROR: empty queue')
        writeHeartbeat('empty-queue')
        if showDialog then
            LrDialogs.message('Reality Processor', 'HDR fronta je prázdná.', 'warning')
        end
        return false
    end

    local catalog = LrApplication.activeCatalog()
    local missingPaths = {}
    local seenMissing = {}

    writeHeartbeat('scanning-catalog')

    for _, group in ipairs(manifest.groups) do
        for _, photoPath in ipairs(group.paths or {}) do
            if not catalog:findPhotoByPath(photoPath) and not seenMissing[photoPath] then
                seenMissing[photoPath] = true
                table.insert(missingPaths, photoPath)
            end
        end
    end

    if #missingPaths > 0 then
        writeHeartbeat('waiting-for-catalog-write')

        catalog:withWriteAccessDo('Reality Processor import', function()
            for index, photoPath in ipairs(missingPaths) do
                writeHeartbeat('importing:' .. tostring(index) .. '/' .. tostring(#missingPaths))
                if not catalog:findPhotoByPath(photoPath) then
                    catalog:addPhoto(photoPath)
                end
            end
        end, { timeout = 30 })
    end

    writeHeartbeat('import-complete')
    LrTasks.yield()

    local importedCount = 0
    writeHeartbeat('rebuilding-groups')

    for _, group in ipairs(manifest.groups) do
        group.photos = {}
        for _, photoPath in ipairs(group.paths or {}) do
            local photo = catalog:findPhotoByPath(photoPath)
            if photo then
                table.insert(group.photos, photo)
                importedCount = importedCount + 1
            end
        end
    end

    writeHeartbeat('groups-ready:' .. tostring(importedCount))

    -- Vytvořit kolekci podle lokálního data a času Lightroomu.
    local collectionName = 'RealityProcessor ' .. LrDate.timeToUserFormat(
        LrDate.currentTime(),
        '%Y-%m-%d %H-%M-%S',
        false
    )
    local collection = nil

    writeHeartbeat('creating-collection:' .. collectionName)
    catalog:withWriteAccessDo('Reality Processor create collection', function()
        collection = catalog:createCollection(collectionName, nil, true)
    end, { timeout = 30 })

    LrTasks.yield()

    if not collection then
        writeAck('ERROR: nepodařilo se vytvořit kolekci ' .. collectionName)
        writeHeartbeat('collection-error')
        return false
    end

    local sourcePhotos = uniquePhotosFromGroups(manifest.groups)
    writeHeartbeat('adding-to-collection:' .. tostring(#sourcePhotos))
    catalog:withWriteAccessDo('Reality Processor add source photos', function()
        collection:addPhotos(sourcePhotos)
    end, { timeout = 30 })

    writeHeartbeat('collection-ready:' .. collectionName)
    LrTasks.yield()

    -- HDR merge po jedné sérii. Po každé sérii čekáme, až se v katalogu objeví nový DNG,
    -- teprve potom spustíme další. Tím se Lightroom nepřetíží dávkou příkazů najednou.
    local mergedCount = 0

    for groupIndex, group in ipairs(manifest.groups) do
        if group.photos and #group.photos >= 2 then
            writeHeartbeat('hdr-selecting:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            selectGroup(catalog, group.photos)
            LrTasks.sleep(0.3)

            local beforeIds = {}
            for _, photo in ipairs(catalog:getAllPhotos()) do
                if photo.localIdentifier then
                    beforeIds[photo.localIdentifier] = true
                end
            end

            writeHeartbeat('hdr-triggering:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            local status = runHeadlessHDRMerge()
            if status ~= 0 then
                local message = 'Nepodařilo se spustit HDR merge přes macOS automatizaci (osascript exit ' .. tostring(status) .. '). Povol Adobe Lightroom Classic v Nastavení systému > Soukromí a zabezpečení > Zpřístupnění.'
                writeAck('ERROR: ' .. message)
                writeHeartbeat('hdr-trigger-error:' .. tostring(groupIndex))
                return false
            end

            local newPhotos = waitForNewCatalogPhoto(catalog, beforeIds, 180, groupIndex, #manifest.groups)
            if not newPhotos or #newPhotos == 0 then
                local message = 'HDR merge série ' .. tostring(groupIndex) .. ' se do 180 s nedokončil.'
                writeAck('ERROR: ' .. message)
                writeHeartbeat('hdr-timeout:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
                return false
            end

            mergedCount = mergedCount + 1
            writeHeartbeat('hdr-created:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))

            catalog:withWriteAccessDo('Reality Processor add HDR result', function()
                collection:addPhotos(newPhotos)
            end, { timeout = 30 })

            LrTasks.sleep(0.5)
        end
    end

    writeHeartbeat('selecting-collection')
    -- Po dokončení vybereme první výsledek/zdroj pro jistotu, samotná kolekce už je připravená.
    local firstGroup = manifest.groups[1]
    if firstGroup and #firstGroup.photos > 0 then
        selectGroup(catalog, firstGroup.photos)
    end

    writeHeartbeat('writing-ack')
    writeAck(
        'OK|' .. tostring(#manifest.groups) ..
        '|' .. tostring(importedCount) ..
        '|' .. tostring(mergedCount) ..
        '|' .. collectionName
    )
    writeHeartbeat('processed')

    if showDialog then
        LrDialogs.message(
            'Reality Processor',
            'Hotovo: ' .. tostring(mergedCount) .. ' HDR z ' .. tostring(#manifest.groups) .. ' sérií.\n\nKolekce: ' .. collectionName,
            'info'
        )
    end

    return true
end

local function consumeTrigger()
    local trigger = triggerPath()
    if not LrFileUtils.exists(trigger) then
        return false
    end

    writeHeartbeat('trigger-received')

    local ok, err = LrTasks.pcall(function()
        LrFileUtils.delete(trigger)
    end)

    if not ok or LrFileUtils.exists(trigger) then
        writeHeartbeat('trigger-delete-error:' .. tostring(err))
        writeAck('ERROR: nepodařilo se odstranit HDR trigger')
        return false
    end

    writeHeartbeat('trigger-consumed')
    return true
end

if not _G.RealityProcessorBridgeStarted then
    _G.RealityProcessorBridgeStarted = true
    _G.RealityProcessorQueueBusy = false

    LrTasks.startAsyncTask(function()
        writeHeartbeat('started')

        while true do
            if not _G.RealityProcessorQueueBusy then
                writeHeartbeat('alive')

                if consumeTrigger() then
                    _G.RealityProcessorQueueBusy = true

                    local ok, result = LrTasks.pcall(processQueue, false)
                    if not ok then
                        writeHeartbeat('processor-error:' .. tostring(result))
                        writeAck('ERROR: ' .. tostring(result))
                    elseif result == false then
                        writeHeartbeat('processor-failed')
                    end

                    _G.RealityProcessorQueueBusy = false
                end
            end

            LrTasks.sleep(1)
        end
    end)
end
