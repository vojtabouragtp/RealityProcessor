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
    if not chunk then return nil, err end
    local ok, manifest = pcall(chunk)
    if not ok then return nil, manifest end
    return manifest, nil
end

local function uniquePhotosFromGroups(groups)
    local result, seen = {}, {}
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
    if not photos or #photos == 0 then return false end
    local active = photos[1]
    local others = {}
    for i = 2, #photos do table.insert(others, photos[i]) end
    catalog:setSelectedPhotos(active, others)
    return true
end

local function runHeadlessHDRMerge()
    -- Lightroom Classic macOS: Control+Shift+H = headless HDR merge.
    -- Nejdřív přepneme na Library Grid (G), počkáme na UI a pak pošleme zkratku.
    -- Používáme key code, aby to nebylo závislé na rozložení klávesnice.
    local command = [[/usr/bin/osascript \
-e 'tell application "Adobe Lightroom Classic" to activate' \
-e 'delay 0.8' \
-e 'tell application "System Events"' \
-e '  tell process "Adobe Lightroom Classic"' \
-e '    set frontmost to true' \
-e '    key code 5' \
-e '    delay 0.8' \
-e '    key code 4 using {control down, shift down}' \
-e '  end tell' \
-e 'end tell' \
>/tmp/realityprocessor_hdr_osascript.log 2>&1]]
    return LrTasks.execute(command)
end

local function waitForNewCatalogPhoto(catalog, beforeIds, timeoutSeconds, groupIndex, groupCount)
    local deadline = LrDate.currentTime() + timeoutSeconds
    while LrDate.currentTime() < deadline do
        local newPhotos = {}
        for _, photo in ipairs(catalog:getAllPhotos()) do
            local id = photo.localIdentifier
            if id and not beforeIds[id] then table.insert(newPhotos, photo) end
        end
        if #newPhotos > 0 then return newPhotos end
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
        return false
    end
    if not manifest.groups or #manifest.groups == 0 then
        writeAck('ERROR: empty queue')
        writeHeartbeat('empty-queue')
        return false
    end

    local catalog = LrApplication.activeCatalog()
    local missingPaths, seenMissing = {}, {}
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
                if not catalog:findPhotoByPath(photoPath) then catalog:addPhoto(photoPath) end
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

    local collectionName = manifest.collectionName
    if not collectionName or collectionName == '' then
        collectionName = 'RealityProcessor ' .. LrDate.timeToUserFormat(LrDate.currentTime(), '%Y-%m-%d %H-%M-%S', false)
    end

    local collection = nil
    writeHeartbeat('creating-collection:' .. collectionName)
    catalog:withWriteAccessDo('Reality Processor create collection', function()
        collection = catalog:createCollection(collectionName, nil, true)
    end, { timeout = 30 })

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

    writeHeartbeat('collection-added:' .. tostring(#sourcePhotos))
    LrTasks.yield()

    -- Udělat kolekci skutečně viditelnou/aktivní v levém panelu Lightroomu.
    local okSource, sourceErr = LrTasks.pcall(function()
        catalog:setActiveSources({ collection })
    end)
    if okSource then
        writeHeartbeat('collection-active:' .. collectionName)
    else
        writeHeartbeat('collection-active-warning:' .. tostring(sourceErr))
    end
    LrTasks.sleep(0.8)

    local mergedCount = 0
    for groupIndex, group in ipairs(manifest.groups) do
        if group.photos and #group.photos >= 2 then
            writeHeartbeat('hdr-selecting:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            selectGroup(catalog, group.photos)
            LrTasks.sleep(1.0)

            local beforeIds = {}
            for _, photo in ipairs(catalog:getAllPhotos()) do
                if photo.localIdentifier then beforeIds[photo.localIdentifier] = true end
            end

            writeHeartbeat('hdr-triggering:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            local status = runHeadlessHDRMerge()
            if status ~= 0 then
                local message = 'HDR zkratku se nepodařilo poslat (osascript exit ' .. tostring(status) .. '). Zkontroluj macOS Zpřístupnění pro Adobe Lightroom Classic.'
                writeAck('ERROR: ' .. message)
                writeHeartbeat('hdr-trigger-error:' .. tostring(groupIndex) .. ':exit-' .. tostring(status))
                return false
            end

            writeHeartbeat('hdr-command-sent:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            local newPhotos = waitForNewCatalogPhoto(catalog, beforeIds, 180, groupIndex, #manifest.groups)
            if not newPhotos or #newPhotos == 0 then
                local message = 'HDR merge série ' .. tostring(groupIndex) .. ' se do 180 s nedokončil. Zkratka byla odeslána, ale v katalogu nepřibyl nový snímek.'
                writeAck('ERROR: ' .. message)
                writeHeartbeat('hdr-timeout:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
                return false
            end

            mergedCount = mergedCount + 1
            writeHeartbeat('hdr-created:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            catalog:withWriteAccessDo('Reality Processor add HDR result', function()
                collection:addPhotos(newPhotos)
            end, { timeout = 30 })
            LrTasks.sleep(0.8)
        end
    end

    local okFinal = LrTasks.pcall(function()
        catalog:setActiveSources({ collection })
    end)
    if okFinal then writeHeartbeat('collection-final-active') end

    writeHeartbeat('writing-ack')
    writeAck('OK|' .. tostring(#manifest.groups) .. '|' .. tostring(importedCount) .. '|' .. tostring(mergedCount) .. '|' .. collectionName)
    writeHeartbeat('processed')

    if showDialog then
        LrDialogs.message('Reality Processor', 'Hotovo: ' .. tostring(mergedCount) .. ' HDR z ' .. tostring(#manifest.groups) .. ' sérií.\n\nKolekce: ' .. collectionName, 'info')
    end
    return true
end

local function consumeTrigger()
    local trigger = triggerPath()
    if not LrFileUtils.exists(trigger) then return false end
    writeHeartbeat('trigger-received')
    local ok, err = LrTasks.pcall(function() LrFileUtils.delete(trigger) end)
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
