##############################################################################
# modules/keyvault/main.tf
#
# Ce module centralise la gestion des secrets de BlockHash dans Azure Key
# Vault, conformément au principe "zéro secret en dur" :
#
#   - Le mot de passe administrateur MySQL est généré dynamiquement
#     (random_password) : sa valeur n'apparaît JAMAIS littéralement dans
#     le code source .tf.
#   - La paire de clés SSH de la VM est générée dynamiquement par Terraform
#     (tls_private_key) : l'utilisateur n'a aucune clé à fournir.
#   - Ces secrets sont stockés dans Key Vault, protégé par RBAC Azure
#     (enable_rbac_authorization = true) plutôt que par des "access
#     policies" historiques.
#   - Seule l'identité managée système de la VM (rattachée après coup via
#     un role assignment au niveau racine) pourra LIRE ces secrets au
#     démarrage — jamais les scripts Terraform/cloud-init ne les
#     manipulent en clair au-delà de leur écriture initiale dans le Vault.
#
# NOTE IMPORTANTE : le state Terraform contient nécessairement ces valeurs
# (c'est un pré-requis technique incontournable pour que Terraform puisse
# créer les ressources Azure qui en dépendent, ex: administrator_password
# du serveur MySQL). Le state DOIT donc être stocké sur un backend distant
# chiffré (ex: Azure Storage Account avec chiffrement + accès restreint),
# jamais versionné en clair dans Git. Voir README.md.
##############################################################################

# ----------------------------------------------------------------------------
# Déclaration explicite des providers utilisés par ce module (au-delà du
# provider azurerm hérité implicitement du module racine) : bonne pratique
# Terraform pour tout module utilisant des providers additionnels comme
# "random", "tls" ou "time".
# ----------------------------------------------------------------------------
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    random = {
      source = "hashicorp/random"
    }
    tls = {
      source = "hashicorp/tls"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

data "azurerm_client_config" "current" {}

# ----------------------------------------------------------------------------
# Suffixe aléatoire court : garantit l'unicité globale du nom du Key Vault
# (contrainte Azure : nom unique sur l'ensemble du cloud public, 3-24
# caractères). Le même principe est réutilisé par le module database pour
# le nom du serveur MySQL (également unique globalement).
# ----------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  # Nom du Key Vault, tronqué à 24 caractères (limite Azure) et nettoyé de
  # tout caractère non autorisé (seuls alphanumériques et tirets acceptés).
  key_vault_name = substr(
    lower(replace("kv-${var.project_name}-${var.environment}-${random_string.suffix.result}", "/[^a-zA-Z0-9-]/", "-")),
    0, 24
  )
}

# ----------------------------------------------------------------------------
# Génération dynamique du mot de passe administrateur MySQL.
# Longueur 24, caractères spéciaux restreints (compatibilité shell/MySQL).
# ----------------------------------------------------------------------------
resource "random_password" "mysql_admin_password" {
  length           = 24
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

# ----------------------------------------------------------------------------
# Génération dynamique du mot de passe administrateur du DASHBOARD DE
# MONITORING (interface web protégée par authentification, voir
# modules/vm/scripts/user_data.sh). Distinct du mot de passe MySQL afin de
# ne jamais réutiliser un même secret pour deux usages différents.
# ----------------------------------------------------------------------------
resource "random_password" "dashboard_admin_password" {
  length           = 20
  special          = true
  override_special = "!#%&*()-_=+"
}

# ----------------------------------------------------------------------------
# Génération dynamique de la paire de clés SSH (RSA 4096) utilisée pour
# l'authentification sur la VM Web. La clé privée est automatiquement
# marquée "sensitive" par le provider TLS (jamais affichée en clair dans
# les logs "terraform plan/apply").
# ----------------------------------------------------------------------------
resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ----------------------------------------------------------------------------
# Azure Key Vault — coffre-fort central des secrets BlockHash.
# ----------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC Azure plutôt qu'access policies : gouvernance centralisée via IAM,
  # cohérente avec les autres ressources de l'abonnement.
  enable_rbac_authorization = true

  # Protection contre la suppression définitive accidentelle. Peut être
  # désactivée en environnement de test pour faciliter les cycles
  # destroy/apply répétés (voir var.purge_protection_enabled).
  purge_protection_enabled  = var.purge_protection_enabled
  soft_delete_retention_days = 7

  # Autorise l'accès depuis Internet (VM et poste d'administration) tout en
  # gardant le contrôle d'accès au niveau RBAC. Peut être restreint via
  # network_acls en environnement de production stricte.
  public_network_access_enabled = true

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Attribution du rôle "Key Vault Secrets Officer" à l'identité qui exécute
# Terraform (utilisateur ou Service Principal). Indispensable car, avec
# enable_rbac_authorization = true, AUCUN accès n'est implicite : même le
# propriétaire de l'abonnement ne peut pas écrire de secret sans ce rôle.
# ----------------------------------------------------------------------------
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ----------------------------------------------------------------------------
# Pause technique : les attributions de rôle RBAC Azure peuvent mettre
# jusqu'à quelques dizaines de secondes à se propager. Sans cette pause,
# la création des secrets juste après peut échouer de façon intermittente
# avec une erreur 403 (Forbidden) sur un premier déploiement.
# ----------------------------------------------------------------------------
resource "time_sleep" "wait_for_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.deployer_secrets_officer]
  create_duration = "30s"
}

# ----------------------------------------------------------------------------
# Secret : login administrateur MySQL.
# ----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "mysql_admin_login" {
  name         = "mysql-admin-login"
  value        = var.mysql_admin_login
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

# ----------------------------------------------------------------------------
# Secret : mot de passe administrateur MySQL généré dynamiquement.
# ----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "mysql_admin_password" {
  name         = "mysql-admin-password"
  value        = random_password.mysql_admin_password.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

# ----------------------------------------------------------------------------
# Secret : clé privée SSH générée dynamiquement — permet à l'administrateur
# de la récupérer a posteriori (ex: `az keyvault secret show`) même après
# avoir perdu la copie initiale fournie par "terraform output".
# ----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "ssh_private_key" {
  name         = "vm-ssh-private-key"
  value        = tls_private_key.vm_ssh.private_key_pem
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

# ----------------------------------------------------------------------------
# Secret : URL de webhook d'alerte (Discord/Slack). Traitée comme un secret
# car elle permet d'envoyer des messages au nom de BlockHash si elle fuite.
# Créée uniquement si une valeur non vide est fournie (count conditionnel).
# ----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "alert_webhook_url" {
  count = var.alert_webhook_url != "" ? 1 : 0

  name         = "alert-webhook-url"
  value        = var.alert_webhook_url
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}

# ----------------------------------------------------------------------------
# Secret : mot de passe administrateur du dashboard de monitoring, généré
# dynamiquement. Consommé par la VM au démarrage pour protéger l'accès web
# au dashboard derrière une page de connexion (voir user_data.sh).
# ----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "dashboard_admin_password" {
  name         = "dashboard-admin-password"
  value        = random_password.dashboard_admin_password.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [time_sleep.wait_for_rbac_propagation]
}
