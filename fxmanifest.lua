fx_version 'cerulean'
game 'gta5'

description 'ESX Company Job'

shared_scripts {
    '@es_extended/locale.lua',
    'locales/en.lua',
    'config.lua'
}
server_scripts {'@mysql-async/lib/MySQL.lua', 'server/logs_config.lua', 'server/logs.lua', 'server/main.lua'}
client_script 'client/main.lua'
dependencies {
    'es_extended', 'mysql-async', 'esx_society', 'esx_addonaccount',
    'esx_addoninventory', 'esx_datastore', '/onesync'
}
