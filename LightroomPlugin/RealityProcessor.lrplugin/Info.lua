return {
    LrSdkVersion = 12.0,
    LrSdkMinimumVersion = 3.0,
    LrToolkitIdentifier = 'com.vojtaboura.realityprocessor',
    LrPluginName = 'Reality Processor',
    VERSION = { major = 1, minor = 1, revision = 0, build = 0 },

    -- Library -> Plug-in Extras
    LrLibraryMenuItems = {
        {
            title = 'Reality Processor: Načíst HDR frontu',
            file = 'LoadHDRQueue.lua',
        },
    },

    -- Fallback: File -> Plug-in Extras
    LrExportMenuItems = {
        {
            title = 'Reality Processor: Načíst HDR frontu',
            file = 'LoadHDRQueue.lua',
        },
    },
}
