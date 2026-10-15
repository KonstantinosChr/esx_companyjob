FiveM Company Job

This is a comprehensive company job script for FiveM, based on the ESX framework. It allows players to work as truck drivers, team up in convoys, and generate revenue and items for the company. It also includes advanced interaction features for higher-ranking company members.

🌟 Features

Multi-Tier Grade System: Includes 4 distinct grades: Recruit, Transporter, Underboss, and Boss.

Convoy System: Players can register for a convoy. The final payout scales dynamically based on how many players participated in the same convoy, encouraging teamwork.

Dynamic Depot: When a player finishes a delivery (stores their trailer), random items from a configured list are automatically deposited into the company's depot (society_companyjob_depot).

Boss Management: Full boss menu integration for managing employees, company funds, and the company vault (society_companyjob).

Advanced Interactions: Higher ranks (Underboss and Boss) have access to a custom F6 menu allowing them to:

Issue bills/invoices.

Search players (confiscate illegal items, weapons, or dirty money).

Handcuff, blindfold, drag, and place players in/out of vehicles.

Cloakroom & Uniforms: Pre-configured work uniforms for male and female characters based on their grade.

Company Garage: Spawn and store company-owned vehicles.

📋 Requirements

To run this script, your server must have the following dependencies installed:

es_extended (ESX Framework)

esx_society

esx_addonaccount

esx_addoninventory

esx_datastore

esx_billing

mysql-async (or modern equivalents like oxmysql with backward compatibility)

🛠️ Installation

Download and Extract: Place the script folder into your server's resources directory and name it companyjob (or whatever your resource folder is named).

Database Setup:

Import the provided companyjob.sql file into your database.

This will create the job, the job grades (recruit, transporter, underboss, boss), the addon accounts/inventories, and the two required tables for the convoy system (convoy_list and convoy_registered_list).

Check Items (CRITICAL):

Open config.lua (or config_2.lua) and scroll down to Config.listItems.

Make sure that every single item listed in this array exists in your database's items table. If the script attempts to give an item that doesn't exist, it will cause errors. Remove or replace any items you do not use on your server.

Server Configuration: Add the following line to your server.cfg:

ensure companyjob


⚙️ Configuration (config.lua)

The script is highly customizable. Open the config.lua file to edit:

Config.Locale: Set your language (e.g., 'en', 'gr').

Config.Zones: Adjust coordinates for the cloakroom, garage, vehicle spawn points, boss actions, trailer spawns, and payment zones.

Config.Uniforms: Change the clothing IDs for male and female uniforms per grade.

Config.AuthorizedVehicles: Modify the list and prices of vehicles available in the company garage.

Config.Pay: Adjust how much the player and the society earn based on the number of people in the convoy.

📝 Note on Resource Manifest

This script supports both the legacy __resource.lua and the modern fxmanifest.lua. 
