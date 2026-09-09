local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

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

local function triggerPath()
    return LrPathUtils.child(supportFolder(), 'pending_hdr.trigger')
end

local function loadQueueScript()
    return LrPathUtils.child(_PLUGIN.path, 'LoadHDRQueue.lua')
end

LrTasks.startAsyncTask(function()
    while true do
        local trigger = triggerPath()
        local handle = io.open(trigger, 'r')

        if handle then
            handle:close()
            os.remove(trigger)

            local ok, err = pcall(dofile, loadQueueScript())
            if not ok then
                -- Menu item remains available as a manual fallback.
                print('Reality Processor background bridge error: ' .. tostring(err))
            end
        end

        LrTasks.sleep(1)
    end
end)
