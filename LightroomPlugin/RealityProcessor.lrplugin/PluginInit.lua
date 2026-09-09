local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'

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

local function heartbeatPath()
    return LrPathUtils.child(supportFolder(), 'lightroom_bridge.heartbeat')
end

local function processorPath()
    return LrPathUtils.child(_PLUGIN.path, 'QueueProcessor.lua')
end

local function writeHeartbeat(text)
    local handle = io.open(heartbeatPath(), 'w')
    if handle then
        handle:write(text or 'alive')
        handle:close()
    end
end

LrTasks.startAsyncTask(function()
    writeHeartbeat('started')

    local ok, processor = pcall(dofile, processorPath())
    if not ok or type(processor) ~= 'function' then
        writeHeartbeat('processor-load-error:' .. tostring(processor))
        return
    end

    while true do
        writeHeartbeat('alive')
        local trigger = triggerPath()

        if LrFileUtils.exists(trigger) then
            pcall(function()
                LrFileUtils.delete(trigger)
            end)

            local success, err = pcall(processor, false)
            if not success then
                writeHeartbeat('processor-error:' .. tostring(err))
            else
                writeHeartbeat('processed')
            end
        end

        LrTasks.sleep(1)
    end
end)
