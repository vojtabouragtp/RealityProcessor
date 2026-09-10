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

local function hdrSettingsPath()
    return LrPathUtils.child(supportFolder(), 'hdr_settings.lua')
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

local function loadLuaTable(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return value, nil
end

local function loadManifest(path)
    return loadLuaTable(path)
end

local function loadHDRSettings()
    local defaults = {
        autoAlign = true,
        autoSettings = false,
        deghost = 'None',
        showDeghostOverlay = false,
        createStack = true,
    }

    if not LrFileUtils.exists(hdrSettingsPath()) then
        return defaults
    end

    local settings = loadLuaTable(hdrSettingsPath())
    if not settings then return defaults end

    if settings.autoAlign ~= nil then defaults.autoAlign = settings.autoAlign end
    if settings.autoSettings ~= nil then defaults.autoSettings = settings.autoSettings end
    if settings.deghost ~= nil then defaults.deghost = settings.deghost end
    if settings.showDeghostOverlay ~= nil then defaults.showDeghostOverlay = settings.showDeghostOverlay end
    if settings.createStack ~= nil then defaults.createStack = settings.createStack end

    return defaults
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

local function appleBool(value)
    return value and 'true' or 'false'
end

local function runHDRMerge(settings)
    -- Lightroomův HDR dialog nemá na všech verzích stejné Accessibility názvy.
    -- Tato verze proto nepředpokládá, že checkbox má name="Auto Align".
    -- Nejdřív zkouší názvy/description a pak bezpečný fallback podle pořadí checkboxů.
    local scriptPath = '/tmp/realityprocessor_hdr_merge.applescript'
    local logPath = '/tmp/realityprocessor_hdr_osascript.log'

    local script = [[
set desiredAutoAlign to ]] .. appleBool(settings.autoAlign) .. [[
set desiredAutoSettings to ]] .. appleBool(settings.autoSettings) .. [[
set desiredDeghost to "]] .. tostring(settings.deghost or 'None') .. [["
set desiredOverlay to ]] .. appleBool(settings.showDeghostOverlay) .. [[
set desiredStack to ]] .. appleBool(settings.createStack) .. [[

on safeName(theItem)
    try
        set n to name of theItem
        if n is missing value then return ""
        return n as text
    on error
        return ""
    end try
end safeName

on safeDescription(theItem)
    try
        set d to description of theItem
        if d is missing value then return ""
        return d as text
    on error
        return ""
    end try
end safeDescription

on setCheckboxState(theItem, wanted)
    tell application "System Events"
        try
            set currentValue to value of theItem as integer
            if wanted and currentValue is 0 then perform action "AXPress" of theItem
            if (not wanted) and currentValue is 1 then perform action "AXPress" of theItem
        on error
            try
                set currentValue to value of theItem as integer
                if wanted and currentValue is 0 then click theItem
                if (not wanted) and currentValue is 1 then click theItem
            end try
        end try
    end tell
end setCheckboxState

tell application "Adobe Lightroom Classic" to activate
delay 0.7

tell application "System Events"
    tell process "Adobe Lightroom Classic"
        set frontmost to true
        key code 5
        delay 0.6
        key code 4 using {control down, shift down}
    end tell
end tell

-- Čekáme na dialog podle struktury, ne podle jediného AX názvu.
set dialogReady to false
repeat 160 times
    try
        tell application "System Events"
            tell process "Adobe Lightroom Classic"
                if (count of windows) > 0 then
                    set allItems to entire contents of front window
                    set checkboxCount to 0
                    set buttonCount to 0
                    repeat with uiItem in allItems
                        try
                            if role of uiItem is "AXCheckBox" then set checkboxCount to checkboxCount + 1
                            if role of uiItem is "AXButton" then set buttonCount to buttonCount + 1
                        end try
                    end repeat
                    if checkboxCount >= 4 and buttonCount >= 4 then set dialogReady to true
                end if
            end tell
        end tell
    end try
    if dialogReady then exit repeat
    delay 0.25
end repeat

if dialogReady is false then error "HDR dialog not found: expected at least 4 checkboxes and 4 buttons"

tell application "System Events"
    tell process "Adobe Lightroom Classic"
        set allItems to entire contents of front window
        set allCheckboxes to {}

        repeat with uiItem in allItems
            try
                if role of uiItem is "AXCheckBox" then set end of allCheckboxes to uiItem
            end try
        end repeat

        -- 1) Preferujeme skutečné Accessibility názvy/description, pokud existují.
        set foundAlign to false
        set foundAuto to false
        set foundOverlay to false
        set foundStack to false

        repeat with cb in allCheckboxes
            set labelText to my safeName(cb) & " " & my safeDescription(cb)
            ignoring case
                if labelText contains "auto align" then
                    my setCheckboxState(cb, desiredAutoAlign)
                    set foundAlign to true
                else if labelText contains "auto settings" then
                    my setCheckboxState(cb, desiredAutoSettings)
                    set foundAuto to true
                else if labelText contains "deghost overlay" then
                    my setCheckboxState(cb, desiredOverlay)
                    set foundOverlay to true
                else if labelText contains "create stack" then
                    my setCheckboxState(cb, desiredStack)
                    set foundStack to true
                end if
            end ignoring
        end repeat

        -- 2) Fallback pro Lightroom buildy, kde checkboxy nemají názvy.
        -- V HDR dialogu jsou v pořadí: Auto Align, Auto Settings, Show Deghost Overlay, Create Stack.
        if (count of allCheckboxes) >= 4 then
            if not foundAlign then my setCheckboxState(item 1 of allCheckboxes, desiredAutoAlign)
            if not foundAuto then my setCheckboxState(item 2 of allCheckboxes, desiredAutoSettings)
            if not foundOverlay then my setCheckboxState(item 3 of allCheckboxes, desiredOverlay)
            if not foundStack then my setCheckboxState(item 4 of allCheckboxes, desiredStack)
        end if

        delay 0.25

        -- Deghost: nejdřív podle názvu. Když AX jméno chybí, použijeme pořadí
        -- čtyř velkých tlačítek None/Low/Medium/High v dialogu.
        set deghostClicked to false
        set namedDeghostButtons to {}
        repeat with uiItem in (entire contents of front window)
            try
                if role of uiItem is "AXButton" or role of uiItem is "AXRadioButton" then
                    set n to my safeName(uiItem)
                    if n is "None" or n is "Low" or n is "Medium" or n is "High" then
                        set end of namedDeghostButtons to uiItem
                        if n is desiredDeghost then
                            try
                                perform action "AXPress" of uiItem
                            on error
                                click uiItem
                            end try
                            set deghostClicked to true
                        end if
                    end if
                end if
            end try
        end repeat

        -- Pokud se názvy nepodařilo použít, hledáme čtyři nejširší běžná tlačítka
        -- a z nich vybereme dle indexu. Je to fallback, ne primární cesta.
        if not deghostClicked then
            set wideButtons to {}
            repeat with uiItem in (entire contents of front window)
                try
                    if role of uiItem is "AXButton" then
                        set s to size of uiItem
                        if item 1 of s > 250 then set end of wideButtons to uiItem
                    end if
                end try
            end repeat
            if (count of wideButtons) >= 4 then
                set wantedIndex to 1
                if desiredDeghost is "Low" then set wantedIndex to 2
                if desiredDeghost is "Medium" then set wantedIndex to 3
                if desiredDeghost is "High" then set wantedIndex to 4
                try
                    perform action "AXPress" of item wantedIndex of wideButtons
                    set deghostClicked to true
                on error
                    try
                        click item wantedIndex of wideButtons
                        set deghostClicked to true
                    end try
                end try
            end if
        end if

        delay 0.35

        -- Overlay znovu po změně deghostu, protože Lightroom ho může enable/disable.
        set refreshedCheckboxes to {}
        repeat with uiItem in (entire contents of front window)
            try
                if role of uiItem is "AXCheckBox" then set end of refreshedCheckboxes to uiItem
            end try
        end repeat
        if (count of refreshedCheckboxes) >= 3 then
            set overlayBox to item 3 of refreshedCheckboxes
            try
                if enabled of overlayBox then my setCheckboxState(overlayBox, desiredOverlay)
            end try
        end if

        -- Najít Merge. Preferujeme AX name, potom default-button atribut, nakonec Enter.
        set merged to false
        repeat 320 times
            set currentItems to entire contents of front window
            repeat with uiItem in currentItems
                try
                    if role of uiItem is "AXButton" then
                        set n to my safeName(uiItem)
                        ignoring case
                            if n is "Merge" or n contains "merge" then
                                if enabled of uiItem then
                                    try
                                        perform action "AXPress" of uiItem
                                    on error
                                        click uiItem
                                    end try
                                    set merged to true
                                    exit repeat
                                end if
                            end if
                        end ignoring
                    end if
                end try
            end repeat
            if merged then exit repeat
            delay 0.25
        end repeat

        if merged is false then
            -- Ve standardním HDR dialogu je Merge výchozí akce. Return je poslední fallback.
            key code 36
            delay 0.5
            set merged to true
        end if
    end tell
end tell
]]

    if not writeFile(scriptPath, script) then
        return 90
    end

    local command = '/usr/bin/osascript ' .. scriptPath .. ' >' .. logPath .. ' 2>&1'
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

    local settings = loadHDRSettings()
    writeHeartbeat(
        'hdr-settings:' ..
        'align=' .. tostring(settings.autoAlign) ..
        ',auto=' .. tostring(settings.autoSettings) ..
        ',deghost=' .. tostring(settings.deghost) ..
        ',overlay=' .. tostring(settings.showDeghostOverlay) ..
        ',stack=' .. tostring(settings.createStack)
    )

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
            LrTasks.sleep(0.8)

            local beforeIds = {}
            for _, photo in ipairs(catalog:getAllPhotos()) do
                if photo.localIdentifier then beforeIds[photo.localIdentifier] = true end
            end

            writeHeartbeat('hdr-dialog:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            local status = runHDRMerge(settings)
            if status ~= 0 then
                local logText = ''
                local logHandle = io.open('/tmp/realityprocessor_hdr_osascript.log', 'r')
                if logHandle then
                    logText = logHandle:read('*a') or ''
                    logHandle:close()
                end
                logText = string.gsub(logText, '[\r\n]+', ' ')
                if string.len(logText) > 400 then logText = string.sub(logText, 1, 400) end

                local message = 'HDR dialog automatizace selhala (osascript exit ' .. tostring(status) .. ')'
                if logText ~= '' then message = message .. ': ' .. logText end
                writeAck('ERROR: ' .. message)
                writeHeartbeat('hdr-ui-error:' .. tostring(groupIndex) .. ':exit-' .. tostring(status))
                return false
            end

            writeHeartbeat('hdr-merge-clicked:' .. tostring(groupIndex) .. '/' .. tostring(#manifest.groups))
            local newPhotos = waitForNewCatalogPhoto(catalog, beforeIds, 240, groupIndex, #manifest.groups)
            if not newPhotos or #newPhotos == 0 then
                local message = 'HDR merge série ' .. tostring(groupIndex) .. ' se do 240 s nedokončil.'
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
