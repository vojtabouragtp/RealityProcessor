local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local function homeDir()
    return os.getenv('HOME') or ''
end

local function manifestPath()
    return LrPathUtils.child(
        LrPathUtils.child(
            LrPathUtils.child(homeDir(), 'Library'),
            'Application Support'
        ),
        'RealityProcessor/pending_hdr.lua'
    )
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

LrTasks.startAsyncTask(function()
    local path = manifestPath()
    local manifest, err = loadManifest(path)

    if not manifest then
        LrDialogs.message(
            'Reality Processor',
            'HDR frontu se nepodařilo načíst.\n\n' .. tostring(err or path),
            'critical'
        )
        return
    end

    if not manifest.groups or #manifest.groups == 0 then
        LrDialogs.message('Reality Processor', 'HDR fronta je prázdná.', 'warning')
        return
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

    LrDialogs.message(
        'Reality Processor',
        'Načteno ' .. tostring(#manifest.groups) .. ' HDR sérií (' .. tostring(importedCount) .. ' RAWů).\n\nPrvní série je vybraná. Teď ověříme automatické spuštění Photo Merge → HDR.',
        'info'
    )
end)
