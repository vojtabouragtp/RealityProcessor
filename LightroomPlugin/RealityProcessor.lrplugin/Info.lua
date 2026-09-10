return {
    LrSdkVersion = 12.0,
    LrSdkMinimumVersion = 3.0,
    LrToolkitIdentifier = 'com.vojtaboura.realityprocessor',
    LrPluginName = 'Reality Processor',
    VERSION = { major = 2, minor = 0, revision = 0, build = 0 },

    LrInitPlugin = 'LoadHDRQueue.lua',
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
