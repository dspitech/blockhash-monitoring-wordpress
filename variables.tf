##############################################################################
# variables.tf - Déclaration de toutes les variables d'entrée du projet racine
##############################################################################

# ----------------------------------------------------------------------------
# Identité du projet - utilisé pour préfixer/nommer toutes les ressources
# de façon cohérente (convention de nommage Azure).
# ----------------------------------------------------------------------------
variable "project_name" {
  description = "Nom court du projet, utilisé comme préfixe de nommage des ressources Azure."
  type        = string
  default     = "blockhash"
}

variable "environment" {
  description = "Environnement de déploiement (prod, staging, dev...)."
  type        = string
  default     = "prod"
}

# ----------------------------------------------------------------------------
# Localisation Azure - région où seront déployées TOUTES les ressources.
# Valeur demandée par BlockHash : Norway East.
# ----------------------------------------------------------------------------
variable "location" {
  description = "Région Azure de déploiement de l'infrastructure."
  type        = string
  default     = "norwayeast"
}

# ----------------------------------------------------------------------------
# Réseau - plages CIDR du VNet et des sous-réseaux.
# ----------------------------------------------------------------------------
variable "vnet_address_space" {
  description = "Plage d'adresses CIDR du Virtual Network principal."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "web_subnet_prefix" {
  description = "Plage CIDR du sous-réseau Web (héberge la VM Nginx/WordPress/MySQL local)."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

# ----------------------------------------------------------------------------
# ETAPE 1 (durcissement réseau, gratuit) : IP source autorisée pour le SSH.
# A renseigner dans terraform.tfvars avec votre IP publique en /32
# (ex. "90.12.34.56/32"). Trouvez la vôtre avec : curl -4 ifconfig.me
# Laisser "*" revient à ouvrir SSH au monde entier - déconseillé.
# ----------------------------------------------------------------------------
variable "ssh_allowed_source_ip" {
  description = "IP (ou plage CIDR) autorisée en SSH sur la VM. Exemple : \"90.12.34.56/32\"."
  type        = string
  default     = "*"
}

# ----------------------------------------------------------------------------
# Base de données MySQL - INSTALLATION LOCALE SUR LA VM (v2)
#
# Azure Database for MySQL Flexible Server a été abandonné : l'abonnement
# Azure for Students utilisé pour ce projet renvoie l'erreur
# "ProvisionNotSupportedForRegion" sur toutes les régions autorisées par
# Policy (confirmé également par un InternalServerError sur
# `az mysql flexible-server list-skus`), signe d'un blocage au niveau du
# service lui-même plutôt que de la région. MySQL Server est donc installé
# et configuré directement sur la VM Web via cloud-init (voir
# modules/vm/scripts/user_data.sh). Le login/mot de passe restent générés
# dynamiquement et stockés dans Key Vault (aucun changement sur ce point).
# ----------------------------------------------------------------------------
variable "mysql_admin_login" {
  description = "Login de l'utilisateur MySQL applicatif créé localement sur la VM."
  type        = string
  default     = "blockhashadmin"
}

variable "mysql_database_name" {
  description = "Nom de la base de données MySQL locale utilisée par WordPress."
  type        = string
  default     = "wordpress"
}

# ----------------------------------------------------------------------------
# Machine Virtuelle (VM Web/WordPress/Dashboard)
# ----------------------------------------------------------------------------
variable "vm_size" {
  description = "Taille (SKU) de la machine virtuelle Azure."
  type        = string
  default     = "Standard_B2s"
}

variable "vm_admin_username" {
  description = "Nom d'utilisateur administrateur SSH de la VM Linux."
  type        = string
  default     = "azureadmin"
}

# NOTE : il n'y a plus de variable "ssh_public_key" à fournir. La paire de
# clés SSH est désormais générée automatiquement par Terraform (module
# keyvault, ressource tls_private_key) et stockée dans Azure Key Vault.
# Récupérez votre clé privée après "terraform apply" via :
#   terraform output -raw vm_ssh_private_key > blockhash_vm_key.pem
#   chmod 600 blockhash_vm_key.pem

# ----------------------------------------------------------------------------
# Key Vault
# ----------------------------------------------------------------------------
variable "keyvault_purge_protection_enabled" {
  description = <<-EOT
    Active la protection contre la purge définitive du Key Vault (recommandé
    "true" en production réelle). Laissé à "false" par défaut pour faciliter
    les cycles destroy/apply en environnement de test/démo.
  EOT
  type    = bool
  default = false
}

# ----------------------------------------------------------------------------
# Alerting (monitoring applicatif dans user_data.sh)
# La valeur du webhook n'est JAMAIS écrite en dur dans les scripts : elle
# est stockée dans Key Vault par le module "keyvault" puis récupérée par la
# VM à l'exécution via son identité managée.
# ----------------------------------------------------------------------------
variable "alert_webhook_url" {
  description = "URL de webhook Discord/Slack, stockée dans Key Vault (jamais en clair dans le code)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alert_email" {
  description = "Adresse email de destination des alertes envoyées via mailutils."
  type        = string
  default     = "ops@blockhash.io"
}

# ----------------------------------------------------------------------------
# Dashboard de monitoring - authentification
# Le mot de passe est généré dynamiquement (module keyvault) et stocké dans
# Key Vault, exactement comme le mot de passe MySQL et la clé SSH : aucune
# saisie manuelle requise.
# ----------------------------------------------------------------------------
variable "dashboard_admin_username" {
  description = "Nom d'utilisateur pour la connexion au dashboard de monitoring."
  type        = string
  default     = "admin"
}

# ----------------------------------------------------------------------------
# Tags - appliqués uniformément à toutes les ressources pour la gouvernance
# et le suivi des coûts (FinOps).
# ----------------------------------------------------------------------------
variable "tags" {
  description = "Map de tags Azure appliqués à toutes les ressources."
  type        = map(string)
  default = {
    project     = "blockhash"
    environment = "prod"
    managed_by  = "terraform"
  }
}

# ----------------------------------------------------------------------------
# ETAPE 8 (observabilité, gratuit dans la limite de 5 Go ingérés/mois) :
# Active un Azure Log Analytics Workspace + l'agent Azure Monitor sur la VM,
# pour centraliser syslog/auth.log/nginx en dehors de la VM elle-même (donc
# consultable même si la VM est down). Peut être désactivé (false) pour
# rester au plus proche de zéro ressource si le quota gratuit inquiète.
# ----------------------------------------------------------------------------
variable "enable_log_analytics" {
  description = "Active le Log Analytics Workspace + l'agent Azure Monitor sur la VM (gratuit jusqu'à 5 Go/mois ingérés)."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# ETAPE 7 (gouvernance, gratuit) : impose le tag "environment" sur toutes
# les ressources du Resource Group via une Azure Policy native (aucun coût,
# aucune ressource facturée - Azure Policy est gratuit).
# ----------------------------------------------------------------------------
variable "enable_tag_policy" {
  description = "Active une Azure Policy imposant le tag 'environment' sur les ressources du Resource Group (gratuit)."
  type        = bool
  default     = true
}
