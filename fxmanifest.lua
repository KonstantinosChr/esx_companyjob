fx_version 'cerulean'
game 'gta5'

description 'Company Job'
version '1.0'

shared_scripts {
    '@es_extended/locale.lua',
    'locales/br.lua',
    'locales/en.lua',
    'locales/fi.lua',
    'locales/fr.lua',
    'locales/sv.lua',
    'locales/pl.lua',
    'config.lua'
}

server_scripts {
    '@mysql-async/lib/MySQL.lua',
    'server/main.lua'
}

client_scripts {
    'client/utils.lua',
    'client/main.lua'
}

dependency 'es_extended'
export 'GeneratePlate'