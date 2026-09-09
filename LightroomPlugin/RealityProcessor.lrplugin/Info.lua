return {
    LrSdkVersion = 12.0,
    LrSdkMinimumVersion = 3.0,
    LrToolkitIdentifier = 'com.vojtaboura.realityprocessor',
    LrPluginName = 'Reality Processor',
    VERSION = { major = 1, minor = 6, revision = 0, build = 0 },

    -- Používáme existující LoadHDRQueue.lua i jako init skript.
    -- Tím se vyhneme problému, kdy Lightroom lokálně neviděl nově přidané Init/PluginInit soubory.
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
