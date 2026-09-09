local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'

local function homeDir()
    return os.getenv('HOME') or ''
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

local function ackPath()
    return LrPathUtils.child(supportFolder(), 'pending_hdr.ack')
end

local function writeAck(text)
    local handle = io.open(ackPath(), 'w')
    if handle then
        handle:write(text or 'OK')
        handle:close()
    end
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

return function(showDialog)
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

    if showDialog then
        LrDialogs.message(
            'Reality Processor',
            'Načteno ' .. tostring(#manifest.groups) .. ' HDR sérií (' .. tostring(importedCount) .. ' RAWů).\n\nPrvní série je vybraná.',
            'info'
        )
    end

    return true
end
