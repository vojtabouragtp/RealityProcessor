return {
    LrSdkVersion = 12.0,
    LrSdkMinimumVersion = 3.0,
    LrToolkitIdentifier = 'com.vojtaboura.realityprocessor',
    LrPluginName = 'Reality Processor',
    VERSION = { major = 1, minor = 4, revision = 0, build = 0 },

    -- Force Lightroom to run Init.lua immediately when the plug-in is loaded.
    LrInitPlugin = 'Init.lua',
    LrForceInitPlugin = true,

    LrLibraryMenuItems = {
        {
            title = 'Reality Processor: Načíst HDR frontu',
            file = 'LoadHDRQueue.lua',
        },
    },

    LrExportMenuItems = {
        {
            title = 'Reality Processor: Načíst HDR frontu',
            file = 'LoadHDRQueue.lua',
        },
    },
}
