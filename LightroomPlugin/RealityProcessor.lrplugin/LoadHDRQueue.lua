local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

LrTasks.startAsyncTask(function()
    local processorPath = LrPathUtils.child(_PLUGIN.path, 'QueueProcessor.lua')
    local ok, processor = pcall(dofile, processorPath)

    if not ok or type(processor) ~= 'function' then
        error('Reality Processor: QueueProcessor.lua se nepodařilo načíst: ' .. tostring(processor))
    end

    processor(true)
end)
