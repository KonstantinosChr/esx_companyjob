-- SERVER ONLY. Set real webhook URLs with `set` in server.cfg (never `setr`).

CompanyLogsConfig = {
    Enabled = true,
    Username = 'Company Job',
    IncludeIdentifier = false,
    DefaultConvar = 'companyjob_webhook',
    Categories = {
        payments = 'companyjob_webhook_payments',
        deliveries = 'companyjob_webhook_deliveries',
        storage = 'companyjob_webhook_storage',
        vehicles = 'companyjob_webhook_vehicles',
        interactions = 'companyjob_webhook_interactions'
    }
}
