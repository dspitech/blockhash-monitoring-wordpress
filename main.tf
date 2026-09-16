##############################################################################
# main.tf — Point d'entrée principal de l'infrastructure BlockHash sur Azure
#
# Ce fichier orchestre 4 modules Terraform (network, keyvault, database, vm).
#
# GESTION DES SECRETS : aucun mot de passe, clé SSH ou identifiant de base
# de données n'est écrit en dur dans ce projet. Toutes les valeurs
# sensibles sont :
#   1. Générées dynamiquement par Terraform (random_password, tls_private_key)
#      dans le module "keyvault"  jamais recopiées littéralement dans le code.
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
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # Permet à "terraform destroy" de purger définitivement le Key Vault
    # même si purge_protection_enabled est resté à "false" (cf. variable
    # keyvault_purge_protection_enabled) — utile en environnement de test.
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

  project_name       = var.project_name
  environment        = var.environment
  location           = var.location
  vnet_address_space = var.vnet_address_space
  web_subnet_prefix  = var.web_subnet_prefix
  db_subnet_prefix   = var.db_subnet_prefix
  tags               = var.tags
}

# ----------------------------------------------------------------------------
# MODULE "keyvault"
# Génère et stocke tous les secrets du projet (mot de passe MySQL, paire de
# clés SSH, webhook d'alerte). Aucune de ces valeurs ne transite par un
# fichier .tfvars ou un script en clair.
# ----------------------------------------------------------------------------
module "keyvault" {
  source = "./modules/keyvault"

  project_name         = var.project_name
  environment          = var.environment
  location             = var.location
  resource_group_name  = module.network.resource_group_name
  mysql_admin_login    = var.mysql_admin_login
  alert_webhook_url    = var.alert_webhook_url
  purge_protection_enabled = var.keyvault_purge_protection_enabled
  tags                 = var.tags

  depends_on = [module.network]
}

# ----------------------------------------------------------------------------
# MODULE "database"
# Consomme le mot de passe MySQL directement depuis les outputs du module
# keyvault (jamais depuis une variable écrite en dur).
# ----------------------------------------------------------------------------
module "database" {
  source = "./modules/database"

  project_name          = var.project_name
  environment           = var.environment
  location              = var.location
  resource_group_name   = module.network.resource_group_name
  db_subnet_id          = module.network.db_subnet_id
  vnet_id               = module.network.vnet_id
  mysql_admin_login     = var.mysql_admin_login
  mysql_admin_password  = module.keyvault.mysql_admin_password
  mysql_sku_name        = var.mysql_sku_name
  mysql_storage_size_gb = var.mysql_storage_size_gb
  mysql_version         = var.mysql_version
  tags                  = var.tags

  depends_on = [module.network]
}

# ----------------------------------------------------------------------------
# MODULE "vm"
# Ne reçoit AUCUN secret en clair : uniquement la clé PUBLIQUE SSH générée
# par le module keyvault, le nom/URI du Key Vault, et les NOMS des secrets
# à aller chercher au démarrage via l'identité managée de la VM.
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

  # Clé publique générée par Terraform (module keyvault) — l'utilisateur
  # n'a besoin de fournir aucune clé SSH lui-même.
  ssh_public_key = module.keyvault.ssh_public_key

  # Références au Key Vault : uniquement des noms/identifiants, jamais des
  # valeurs secrètes. user_data.sh utilisera l'identité managée de la VM
  # pour interroger Key Vault et récupérer les vraies valeurs au démarrage.
  key_vault_name                   = module.keyvault.key_vault_name
  key_vault_uri                    = module.keyvault.key_vault_uri
  mysql_admin_login_secret_name    = module.keyvault.mysql_admin_login_secret_name
  mysql_admin_password_secret_name = module.keyvault.mysql_admin_password_secret_name
  alert_webhook_url_secret_name    = module.keyvault.alert_webhook_url_secret_name

  # Ces valeurs ne sont PAS des secrets : un FQDN et un nom de base de
  # données ne permettent aucune connexion sans les identifiants associés.
  mysql_fqdn          = module.database.mysql_server_fqdn
  mysql_database_name = module.database.mysql_database_name

  alert_email = var.alert_email

  tags = var.tags

  depends_on = [module.database, module.keyvault]
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
