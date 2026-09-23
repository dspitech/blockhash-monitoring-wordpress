##############################################################################
# main.tf - Point d'entrée principal de l'infrastructure BlockHash sur Azure
#
# Ce fichier orchestre 3 modules Terraform (network, keyvault, vm).
#
# NOTE ARCHITECTURE (v2) : MySQL tourne désormais localement sur la VM Web
# (voir modules/vm/scripts/user_data.sh) et non plus sur Azure Database for
# MySQL Flexible Server. Ce choix fait suite à une restriction de service
# constatée sur les abonnements Azure for Students (erreur
# ProvisionNotSupportedForRegion, indépendante de la Policy de région). Le
# module "database" a été retiré du projet ; voir README.md, section
# "Architecture" pour le détail du compromis accepté.
#
# GESTION DES SECRETS : aucun mot de passe, clé SSH ou identifiant de base
# de données n'est écrit en dur dans ce projet. Toutes les valeurs
# sensibles sont :
#   1. Générées dynamiquement par Terraform (random_password, tls_private_key)
#      dans le module "keyvault" - jamais recopiées littéralement dans le code.
#   2. Stockées dans Azure Key Vault (module "keyvault"), protégé par RBAC.
#   3. Récupérées par la VM à l'exécution via son identité managée système
#      (Managed Identity) - le script cloud-init ne reçoit QUE le nom du
#      Key Vault et les NOMS des secrets, jamais leur valeur.
##############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # --------------------------------------------------------------------------
  # ETAPE 5 (gouvernance/sécurité, coût quasi nul) : backend distant.
  #
  # Par défaut, Terraform garde son "state" (qui CONTIENT les secrets, cf.
  # README "Sécurité") en local (terraform.tfstate) : un poste perdu ou un
  # commit malheureux = fuite de secrets + perte de l'historique
  # d'infrastructure. Un backend "azurerm" (Blob Storage) corrige les deux.
  #
  # Coût : un Storage Account "Standard_LRS" avec un fichier de quelques Ko
  # coûte quelques centimes/mois - couvert par le crédit gratuit Azure for
  # Students, ou par le quota de stockage gratuit du free tier Azure (5 Go
  # Blob Storage offerts pendant 12 mois sur un nouveau compte).
  #
  # PROBLEME DE L'OEUF ET DE LA POULE : ce Storage Account ne peut pas être
  # créé PAR ce même Terraform (il faudrait déjà un backend pour le stocker).
  # Créez-le une seule fois avec le script scripts/bootstrap-backend.sh
  # (Azure CLI), puis décommentez le bloc ci-dessous avec les valeurs
  # affichées par ce script, et lancez "terraform init" pour migrer le state
  # local vers ce backend.
  # --------------------------------------------------------------------------
  # backend "azurerm" {
  #   resource_group_name  = "rg-blockhash-tfstate"
  #   storage_account_name = "stblockhashtfstate"   # doit être globalement unique
  #   container_name       = "tfstate"
  #   key                  = "blockhash.prod.tfstate"
  # }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # Permet à "terraform destroy" de purger définitivement le Key Vault
    # même si purge_protection_enabled est resté à "false" (cf. variable
    # keyvault_purge_protection_enabled) - utile en environnement de test.
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

# ----------------------------------------------------------------------------
# MODULE "network"
# ----------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  project_name          = var.project_name
  environment           = var.environment
  location              = var.location
  vnet_address_space    = var.vnet_address_space
  web_subnet_prefix     = var.web_subnet_prefix
  ssh_allowed_source_ip = var.ssh_allowed_source_ip
  tags                  = var.tags
}

# ----------------------------------------------------------------------------
# MODULE "keyvault"
# Génère et stocke tous les secrets du projet (mot de passe MySQL, paire de
# clés SSH, webhook d'alerte). Aucune de ces valeurs ne transite par un
# fichier .tfvars ou un script en clair.
# ----------------------------------------------------------------------------
module "keyvault" {
  source = "./modules/keyvault"

  project_name             = var.project_name
  environment              = var.environment
  location                 = var.location
  resource_group_name      = module.network.resource_group_name
  mysql_admin_login        = var.mysql_admin_login
  alert_webhook_url        = var.alert_webhook_url
  dashboard_admin_username = var.dashboard_admin_username
  purge_protection_enabled = var.keyvault_purge_protection_enabled
  tags                     = var.tags

  depends_on = [module.network]
}

# ----------------------------------------------------------------------------
# MODULE "vm"
# Ne reçoit AUCUN secret en clair : uniquement la clé PUBLIQUE SSH générée
# par le module keyvault, le nom/URI du Key Vault, et les NOMS des secrets
# à aller chercher au démarrage via l'identité managée de la VM.
#
# NOTE ARCHITECTURE (v2) : MySQL tourne désormais LOCALEMENT sur cette VM
# (voir user_data.sh) - il n'y a donc plus de module "database" ni de
# serveur MySQL Flexible Server. Le nom de la base ("wordpress" par défaut)
# est une simple variable non sensible ; le login/mot de passe MySQL restent
# générés et stockés dans Key Vault exactement comme avant, mais servent
# désormais à créer l'utilisateur MySQL LOCAL plutôt qu'à s'authentifier
# auprès d'un serveur managé distant.
# ----------------------------------------------------------------------------
module "vm" {
  source = "./modules/vm"

  project_name        = var.project_name
  environment         = var.environment
  location            = var.location
  resource_group_name = module.network.resource_group_name
  web_subnet_id       = module.network.web_subnet_id
  nsg_id              = module.network.nsg_id
  public_ip_id        = module.network.public_ip_id
  public_ip_address   = module.network.public_ip_address

  vm_size        = var.vm_size
  admin_username = var.vm_admin_username

  # Clé publique générée par Terraform (module keyvault) - l'utilisateur
  # n'a besoin de fournir aucune clé SSH lui-même.
  ssh_public_key = module.keyvault.ssh_public_key

  # Références au Key Vault : uniquement des noms/identifiants, jamais des
  # valeurs secrètes. user_data.sh utilisera l'identité managée de la VM
  # pour interroger Key Vault et récupérer les vraies valeurs au démarrage.
  key_vault_name                       = module.keyvault.key_vault_name
  key_vault_uri                        = module.keyvault.key_vault_uri
  mysql_admin_login_secret_name        = module.keyvault.mysql_admin_login_secret_name
  mysql_admin_password_secret_name     = module.keyvault.mysql_admin_password_secret_name
  alert_webhook_url_secret_name        = module.keyvault.alert_webhook_url_secret_name
  dashboard_admin_password_secret_name = module.keyvault.dashboard_admin_password_secret_name
  dashboard_admin_username             = var.dashboard_admin_username

  # Nom de la base MySQL locale - non sensible.
  mysql_database_name = var.mysql_database_name

  alert_email = var.alert_email

  tags = var.tags

  depends_on = [module.keyvault]
}

# ----------------------------------------------------------------------------
# Attribution du rôle "Key Vault Secrets User" à l'identité managée système
# de la VM Web : lui accorde une lecture SEULE des secrets, requise pour
# que user_data.sh puisse récupérer les identifiants MySQL et le webhook
# d'alerte au démarrage. Ce role assignment vit au niveau racine car il
# dépend simultanément du module "keyvault" (le coffre) et du module "vm"
# (l'identité managée, connue seulement après création de la VM).
# ----------------------------------------------------------------------------
resource "azurerm_role_assignment" "vm_keyvault_secrets_user" {
  scope                = module.keyvault.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.vm.principal_id
}

##############################################################################
# ETAPE 8 - OBSERVABILITE : Log Analytics Workspace + agent Azure Monitor
#
# Objectif : survivre à la panne qu'on est censé détecter. Le monitoring
# actuel (monitor.sh, dashboard Node.js) tourne SUR la VM qu'il surveille :
# si la VM plante ou perd le réseau, plus aucune alerte ne part. En
# centralisant syslog/auth.log/logs Nginx dans un Log Analytics Workspace
# externe, on garde un historique consultable même si la VM est down.
#
# GRATUIT : la tarification "PerGB2018" facture au volume ingéré, MAIS
# chaque abonnement Azure bénéficie d'un quota de 5 Go/mois ingérés
# GRATUITS, à vie (pas seulement pendant les 12 mois du free tier étudiant).
# Pour un usage interne à faible volume (une seule VM), on reste largement
# sous ce seuil. Passez enable_log_analytics = false pour désactiver
# entièrement ce bloc si vous préférez ne prendre aucun risque de dépassement.
##############################################################################
resource "azurerm_log_analytics_workspace" "main" {
  count = var.enable_log_analytics ? 1 : 0

  name                = "log-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = module.network.resource_group_name
  sku                 = "PerGB2018"

  # Retention minimale (30 jours) = incluse gratuitement, au-delà la
  # rétention supplémentaire est facturée. On reste donc au minimum.
  retention_in_days = 30

  tags = var.tags
}

# Agent Azure Monitor (AMA), successeur gratuit du vieil agent "OMS/MMA",
# installé comme extension VM. Il remonte syslog/metrics vers le workspace
# ci-dessus. L'installation de l'extension elle-même est gratuite ; seul le
# volume de données ingérées est (éventuellement) facturé au-delà de 5 Go/mois.
resource "azurerm_virtual_machine_extension" "ama" {
  count = var.enable_log_analytics ? 1 : 0

  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = module.vm.vm_id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.29"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  depends_on = [azurerm_log_analytics_workspace.main]
}

# Règle de collecte de données (DCR) minimale : syslog (auth, daemon, cron)
# et compteurs de performance de base (CPU/RAM/disque), suffisant pour un
# usage interne sans faire gonfler le volume ingéré.
resource "azurerm_monitor_data_collection_rule" "main" {
  count = var.enable_log_analytics ? 1 : 0

  name                = "dcr-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = module.network.resource_group_name
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.main[0].id
      name                  = "log-analytics-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["log-analytics-destination"]
  }

  data_sources {
    syslog {
      name           = "syslog-source"
      facility_names = ["auth", "authpriv", "cron", "daemon", "syslog"]
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "main" {
  count = var.enable_log_analytics ? 1 : 0

  name                    = "dcra-${var.project_name}-${var.environment}"
  target_resource_id      = module.vm.vm_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.main[0].id

  depends_on = [azurerm_virtual_machine_extension.ama]
}

##############################################################################
# ETAPE 7 - GOUVERNANCE : Azure Policy (gratuit, aucune ressource facturée)
#
# Impose que toute nouvelle ressource créée dans ce Resource Group porte le
# tag "environment" - évite la dérive progressive ("on verra plus tard pour
# les tags") qui rend le FinOps et l'audit impossibles à l'échelle.
##############################################################################
resource "azurerm_policy_definition" "require_environment_tag" {
  count = var.enable_tag_policy ? 1 : 0

  name         = "require-environment-tag-${var.project_name}"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Exiger le tag 'environment' sur les ressources BlockHash"

  policy_rule = jsonencode({
    if = {
      field  = "tags['environment']"
      exists = "false"
    }
    then = {
      effect = "deny"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "require_environment_tag" {
  count = var.enable_tag_policy ? 1 : 0

  name                 = "require-environment-tag"
  resource_group_id    = module.network.resource_group_id
  policy_definition_id = azurerm_policy_definition.require_environment_tag[0].id
}
