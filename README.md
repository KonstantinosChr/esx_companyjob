# esx_companyjob

An ESX company resource for FiveM with truck deliveries, shared convoys, company storage, a garage, uniforms and employee management.

## Features

- Four grades: Recruit, Transporter, Underboss and Boss.
- Five initial convoy IDs, with up to eight registered participants per convoy.
- Server-created trailers collected near Paleto Bay and delivered to the Los Santos docks.
- Bank rewards scaled by the number of trailers already delivered in the convoy.
- Random delivery items deposited into the shared company depot.
- Shared vault/depot for standard items and ESX loadout weapons.
- Company vehicle purchases/storage and external vehicleshop checkout integration.
- Grade-specific male/female uniforms and an ESX service menu.
- Boss employee/fund management through `esx_society`.
- F6 billing; restricted search, confiscation, handcuff, escort and vehicle interactions.
- Optional server-only Discord audit logs with per-category webhooks.
- English locale; some labels and notifications remain hardcoded in English.

## Requirements and compatibility

This resource uses **legacy ESX APIs**, including `esx:getSharedObject`. Servers that removed this event need an initialization migration.

| Dependency | Purpose |
| --- | --- |
| FiveM with OneSync/state awareness | Server positions, entities, routing buckets and trailer creation |
| `es_extended` | Shared object, jobs/accounts, game helpers and locale APIs |
| `mysql-async` | Explicit manifest library import and database API |
| `esx_society` | Society registration and boss menu |
| `esx_addonaccount` | Company account |
| `esx_addoninventory` | Shared standard-item inventories |
| `esx_datastore` | Shared weapon storage |
| `esx_service` | Duty callbacks/events used by the shipped client flow |
| `esx_skin`, `skinchanger` | Civilian skin and uniforms |
| `esx_menu_default`, `esx_menu_dialog`, `esx_menu_list` | Action, input and convoy menus |
| Compatible `esx_vehicleshop` | Client `GeneratePlate` export, `retrieveJobVehicles` callback and `setJobVehicleState` event |
| `esx_billing` | F6 invoice action |
| Identity schema, `esx_license`, `esx_status` | Identity/license/drunk data in the default enabled search path |
| Compatible `esx_phone` | Optional society number registration |

The vehicleshop APIs and custom garage columns are installation-specific; a stock ESX server may not provide them. QBCore and replacement inventories such as `ox_inventory` do not have adapters in this package. Installing `oxmysql` alone does not satisfy the explicit `mysql-async` import; migrate and test the database layer if changing drivers.

## Installation

1. Back up your ESX database.
2. Put the `esx_companyjob` directory inside your server's resources directory. Use that exact folder name for the examples below.
3. Install dependencies and confirm the vehicleshop API/schema compatibility.
4. Import `companyjob.sql` into your ESX database. It is a **fresh-install script**, not a repeatable migration; reimporting can cause duplicate-key errors. Existing installations should apply only missing definitions.
5. Verify every `Config.listItems` entry exists in your inventory definitions. Remove or replace unknown/custom items before running deliveries.
6. Verify the garage and identity schemas below.
7. Start this resource after its dependencies.

Example `server.cfg` order, assuming the resources are installed under these names:

```cfg
set onesync on
ensure mysql-async
ensure es_extended
ensure esx_menu_default
ensure esx_menu_dialog
ensure esx_menu_list
ensure esx_addonaccount
ensure esx_addoninventory
ensure esx_datastore
ensure esx_society
ensure esx_service
ensure skinchanger
ensure esx_skin
ensure esx_billing
ensure esx_vehicleshop
# For the default enabled identity/license/status integrations:
ensure esx_identity
ensure esx_license
ensure esx_status
ensure esx_companyjob
```

Follow each dependency's own startup requirements too. Add your compatible phone resource if using society phone registration. Never commit database connection strings or private `server.cfg` files.

Assign `companyjob` through your server's authorized admin command/interface. Grade IDs are 0–3. This resource does not introduce an admin command.

## Database

The SQL installs the following definitions:

| Table | Added data |
| --- | --- |
| `jobs` | `companyjob` |
| `job_grades` | Recruit, Transporter, Underboss, Boss; salaries 200/400/600/800 |
| `addon_account` | Shared `society_companyjob` |
| `addon_inventory` | `society_companyjob` and `society_companyjob_depot` |
| `datastore` | Weapon stores for both vault and depot |
| `convoy_list` | IDs 1–5 |
| `convoy_registered_list` | One row per identifier, convoy ID, delivered flag and paid flag |

ESX/addon resource schemas must already exist. Reward item definitions are not inserted by this script.

The garage requires these `owned_vehicles` columns:

```text
owner, vehicle, plate, type, job, stored, in_garage_type, put_by
```

`vehicle` stores JSON and `stored` is boolean-compatible. `in_garage_type` and `put_by` are custom requirements; adapt them to your garage implementation. No generic migration is provided for an unknown existing schema.

**Require a database unique constraint on `owned_vehicles.plate`.** Resolve existing duplicates first. An application duplicate check alone cannot protect purchases across different players/resources.

Identity-enabled search expects `users.identifier`, `firstname`, `lastname`, `sex`, `dateofbirth` and `height`. Check that `convoy_registered_list.identifier` fits your actual identifiers; the supplied legacy definition is `VARCHAR(50)`.

## Gameplay and controls

1. Receive the company job and select a work outfit/go on duty at the docks cloakroom.
2. Obtain a truck from the company garage. Only a Boss can buy company vehicles; purchases debit that character's cash.
3. Join a convoy at the registration marker.
4. Travel to the Paleto Bay pickup and request a trailer. The server creates and tracks it.
5. Tow that exact trailer to the docks delivery marker. Both player and trailer must reach the area; at least 180 seconds must have elapsed since trailer creation.
6. After an accepted delivery, visit the payment marker for a bank reward.
7. Use the vault/depot according to your grade.

Use **E** at relevant markers and **F6** for job actions. Go on duty through the cloakroom before using the action menu.

Registration and delivery are confirmed by the server. If a payment request is rejected, the client payment marker can disappear; check the player registration and payment state before manually adjusting accounts.

## Permissions

| Action | Server-side restriction |
| --- | --- |
| Convoy registration, trailer, delivery, payment | Company job plus registration/session/position checks |
| Vault read/deposit/withdraw | All company grades, near BossActions |
| Depot read/deposit/withdraw | Company grades except Recruit, near StorageDepot |
| Vehicle purchase | Boss, configured shop preview area, sufficient personal cash |
| Vehicle storage | Company job, garage proximity, nearby networked company vehicle, no connected player inside |
| Search/confiscation, cuff, drag, vehicle interactions | Underboss/Boss, target within 10 m in same routing bucket |
| Account confiscation | `black_money` only |
| Boss management | External `esx_society` authorization must be verified |
| Billing and vehicle checkout | External resource authorization must be verified |

The client normally uses a 3 m interaction radius; the server permits 10 m. Menu visibility is not authorization. Restraint/escort state is largely client-managed; a comprehensive server-owned restraint system is not included.

## Configuration

Edit `config.lua`:

| Setting | Purpose |
| --- | --- |
| `DrawDistance`, `MarkerColor` | Marker render distance/colour |
| `Locale` | `en`; only English ships |
| `MaxInService` | Default 8; -1 skips server service activation, but client service calls remain |
| `EnablePlayerManagement` | Client boss-management marker visibility |
| `EnableESXIdentity` | Identity search query; default true |
| `EnableLicenses` | License data in the identity-enabled path; default true |
| `Blip`, `Cloakrooms` | Map blip and uniform markers |
| `Zones` | Garage, preview interior, spawn points, management, registration, pickup, depot, delivery and payment positions |
| `Uniforms` | Male/female clothing components by grade |
| `AuthorizedVehicles` | Shared/per-grade models, labels and purchase prices |
| `Trailer` | Default `trailers2`, pickup spawn position and heading |
| `Pay` | Player/society payout tiers |
| `listItems` | Weighted random depot reward list; duplicate names increase selection probability |

When moving pickup, change both `Zones.PopTrailer.Pos` and `Trailer.Pos`. Keep garage marker/spawn/preview coordinates consistent. Purchased vehicle JSON stores only model and validated plate; arbitrary client tuning is discarded.

Default payouts:

| Delivered trailers at payment time | Player bank | Society |
| --- | ---: | ---: |
| 1 | 600 | 0 |
| 2 | 800 | 0 |
| 3 | 1,000 | 0 |
| 4 | 1,200 | 0 |
| 5 | 1,400 | 0 |
| 6 | 1,800 | 0 |
| 7 | 2,200 | 0 |
| 8 or more | 3,000 | 0 |

Keep `Pay` non-empty and contiguous, with non-negative numeric rewards. The highest configured tier caps the reward index.

Every accepted delivery makes **50 random selections**, each adding 1–10 items: 50–500 total units. Repeated selections can add the same item. The example list includes valuable/custom items such as gold/diamond. Tune it for your economy and installed item catalog.

## Delivery rules

- Server memory tracks an issued trailer, player/source, convoy, start time and phase.
- Pickup/delivery require routing bucket 0; instance-based jobs need adaptation.
- A player cannot issue another trailer during an active run or replay an accepted delivery for extra rewards.
- The tracked entity/model, proximity and a 180-second minimum are required. These do **not prove the full route was driven** and are not an anti-cheat.
- A conditional database update must claim exactly one row before payment.
- Rewards depend on already delivered trailers when each player collects. Early collectors may receive a lower tier; there is no frozen roster/final payout snapshot.
- Completion resets paid participants when counts indicate all registered members have been paid. Late joins, stale registrations and disconnected members affect the lifecycle; test group workflows.
- Disconnect/resource stop cleans up tracked trailers. Memory sessions are not resumable. Delivered-but-unpaid runs may need administrator reconciliation after a restart.
- An active unpaid run cannot be switched/cancelled through registration. Destroyed trailers may require reconnect/re-registration.
- Database claims and ESX money/items are not one crash-safe transaction. A crash, disconnect or dependency failure after a claim may lose rewards. Reconcile logs/state instead of blindly retrying credits.

## Discord audit logs

Logging is optional and disabled in practice until a valid webhook URL is configured. It is executed only from server code after successful gameplay mutations; no client log event or export is exposed.

### Quick setup

1. Create a webhook for your private Discord log channel through its Integrations settings.
2. Add the URL to your **private `server.cfg`**, before `ensure esx_companyjob`:

```cfg
# Use `set`, never `setr`: this credential must stay server-side.
set companyjob_webhook "YOUR_DISCORD_WEBHOOK_URL"
ensure esx_companyjob
```

Replace the placeholder with the complete Discord webhook URL (`https://discord.com/api/webhooks/...`). The URL validator accepts Discord HTTPS webhook endpoints, including versioned `/api/vN/webhooks/` paths, without query strings. Do not put it in shared `config.lua`, public examples, or Git commits.

For separate channels, set any of the following. Empty/unset category URLs fall back to `companyjob_webhook`:

```cfg
set companyjob_webhook_payments "YOUR_PAYMENTS_WEBHOOK_URL"
set companyjob_webhook_deliveries "YOUR_DELIVERIES_WEBHOOK_URL"
set companyjob_webhook_storage "YOUR_STORAGE_WEBHOOK_URL"
set companyjob_webhook_vehicles "YOUR_VEHICLES_WEBHOOK_URL"
set companyjob_webhook_interactions "YOUR_INTERACTIONS_WEBHOOK_URL"
```

Paste only real URLs for categories you use; remove unused placeholder lines. Keep `server.cfg` out of Git. Do not use replicated `setr` or server-info `sets` for secrets.

### Logged actions

| Category | Successful operations recorded |
| --- | --- |
| `payments` | Worker bank credit with convoy/tier/amount; non-zero society credit separately |
| `deliveries` | Convoy registration/clear, trailer issuance, delivery duration and detailed depot reward item/count batches |
| `storage` | Item/weapon deposit and withdrawal, storage name, count/ammo |
| `vehicles` | Company vehicle purchase with price/model/plate; company vehicle storage |
| `interactions` | Successful item, weapon and dirty-money confiscation with target ID |

Example payment embed:

```text
Worker paid
Player: character name
Server ID: 12
Grade: transporter
Convoy: 2
Bank credit: 1000
Delivered trailer count / tier: 3
Timestamp: UTC
```

Billing, society employee-management changes and vehicle checkout occur in external resources and are not audited by these hooks. This is a successful-operation audit, not a complete log of rejected exploit attempts, restraints or administrative activity.

### Server-only options

`server/logs_config.lua` controls `Enabled`, `Username`, `IncludeIdentifier`, the default convar and category convar names. It is loaded only in `server_scripts`.

`IncludeIdentifier` defaults to **false**. Logs include character name, source ID and grade; enabling it also sends the ESX identifier to Discord. No IP address, full identifier list, webhook URL or token is included in embeds. Restrict channel access and choose suitable retention for your server.

### Delivery behavior

- Bounded in-memory FIFO: up to 200 pending messages, one HTTP request at a time.
- Explicit empty allowed-mentions list to prevent player names from triggering pings.
- HTTP 429 uses Discord `retry_after`; rate-limit response headers affect scheduling.
- Network/server errors receive bounded retries (four total attempts). Other HTTP errors are dropped with a generic console warning.
- Redirects are disabled and webhook hosts are validated.
- Queue overflow drops new events and prints a throttled warning; gameplay continues.
- Logs are best-effort, not a durable financial ledger. Restarts lose pending messages; ambiguous responses can produce duplicate audit messages. Long rate limits may fill the queue.
- A payment log records the ESX credit call returning successfully, not independent confirmation of durable database persistence.

If logs do not arrive, check `Enabled`, convar spelling, the actual URL, Discord webhook permissions/deletion, outbound HTTPS access and generic console status warnings.

References: [Discord webhooks](https://docs.discord.com/developers/resources/webhook) and [rate limits](https://docs.discord.com/developers/topics/rate-limits).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| ESX is nil | Legacy shared-object event support or migrate initialization |
| Unknown SQL column | Garage/identity schema compatibility |
| Missing storage/datastore | Both SQL storage entries and addon resource startup |
| Trailer request rejected | Registration, pickup location, bucket 0 and existing active run |
| Delivery rejected | Exact tracked trailer, player/trailer at depot and 180 seconds elapsed |
| Convoy join rejected | Job, location, full convoy, request in progress or unfinished run |
| Reward item errors | Every configured reward name must exist |
| Missing plate export/garage callback | Vehicleshop adapter/API mismatch |
| Menus do not open | ESX menu dependencies, job and client duty state |
| No Greek locale | Add a complete locale and register it in the manifest |
| Unpaid run after restart | Memory state is lost; reconcile DB/account state manually |

## Repository layout

```text
esx_companyjob/
  client/main.lua
  server/main.lua
  server/logs.lua
  server/logs_config.lua
  locales/en.lua
  config.lua
  companyjob.sql
  fxmanifest.lua
  README.md
```
