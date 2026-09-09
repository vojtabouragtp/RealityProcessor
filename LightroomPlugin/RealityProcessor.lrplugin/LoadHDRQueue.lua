local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'

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

local function ensurePhoto(catalog, path)
    local photo = catalog:findPhotoByPath(path)
    if photo then
        return photo
    end

    local imported
    catalog:withWriteAccessDo('Reality Processor import', function()
        imported = catalog:addPhoto(path)
    end)
    return imported
end

local function processQueue(showDialog)
    local manifest, err = loadManifest(manifestPath())
    if not manifest then
        writeAck('ERROR: ' .. tostring(err))
        if showDialog then
            LrDialogs.message('Reality Processor', 'HDR frontu se nepodařilo načíst.\n\n' .. tostring(err), 'critical')
        end
        return false
    end

    if not manifest.groups or #manifest.groups == 0 then
        writeAck('ERROR: empty queue')
        if showDialog then
            LrDialogs.message('Reality Processor', 'HDR fronta je prázdná.', 'warning')
        end
        return false
    end

    local catalog = LrApplication.activeCatalog()
    local importedCount = 0

    for _, group in ipairs(manifest.groups) do
        group.photos = {}
        for _, photoPath in ipairs(group.paths or {}) do
            local photo = ensurePhoto(catalog, photoPath)
            if photo then
                table.insert(group.photos, photo)
                importedCount = importedCount + 1
            end
        end
    end

    local firstGroup = manifest.groups[1]
    if firstGroup and #firstGroup.photos > 0 then
        local active = firstGroup.photos[1]
        local others = {}
        for i = 2, #firstGroup.photos do
            table.insert(others, firstGroup.photos[i])
        end
        catalog:setSelectedPhotos(active, others)
    end

    writeAck('OK|' .. tostring(#manifest.groups) .. '|' .. tostring(importedCount))
    writeHeartbeat('processed')

    if showDialog then
        LrDialogs.message(
            'Reality Processor',
            'Načteno ' .. tostring(#manifest.groups) .. ' HDR sérií (' .. tostring(importedCount) .. ' RAWů).\n\nPrvní série je vybraná.',
            'info'
        )
    end

    return true
end

-- Tento soubor je zároveň init skript i ruční menu akce.
-- Používáme jen tento jeden existující .lua soubor, aby Lightroom nemusel hledat nové pomocné skripty.
if not _G.RealityProcessorBridgeStarted then
    _G.RealityProcessorBridgeStarted = true

    LrTasks.startAsyncTask(function()
        writeHeartbeat('started')

        while true do
            writeHeartbeat('alive')
            local trigger = triggerPath()

            if LrFileUtils.exists(trigger) then
                pcall(function()
                    LrFileUtils.delete(trigger)
                end)

                local ok, err = pcall(processQueue, false)
                if not ok then
                    writeHeartbeat('processor-error:' .. tostring(err))
                    writeAck('ERROR: ' .. tostring(err))
                end
            end

            LrTasks.sleep(1)
        end
    end)
end

-- Když je skript spuštěn ručně z Plug-in Extras a fronta už čeká,
-- zpracuj ji ihned místo čekání na další tick watcheru.
LrTasks.startAsyncTask(function()
    local trigger = triggerPath()
    if LrFileUtils.exists(trigger) then
        pcall(function()
            LrFileUtils.delete(trigger)
        end)
        processQueue(true)
    end
end)
