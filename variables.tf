##############################################################################
# variables.tf — Déclaration de toutes les variables d'entrée du projet racine
##############################################################################

# ----------------------------------------------------------------------------
# Identité du projet — utilisé pour préfixer/nommer toutes les ressources
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
# Localisation Azure — région où seront déployées TOUTES les ressources.
# Valeur demandée par BlockHash : Norway East.
# ----------------------------------------------------------------------------
variable "location" {
  description = "Région Azure de déploiement de l'infrastructure."
  type        = string
  default     = "norwayeast"
}

# ----------------------------------------------------------------------------
# Réseau — plages CIDR du VNet et des sous-réseaux.
# ----------------------------------------------------------------------------
variable "vnet_address_space" {
  description = "Plage d'adresses CIDR du Virtual Network principal."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "web_subnet_prefix" {
  description = "Plage CIDR du sous-réseau Web (héberge la VM Nginx/WordPress)."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "db_subnet_prefix" {
  description = "Plage CIDR du sous-réseau Database (délégué à MySQL Flexible Server)."
  type        = list(string)
  default     = ["10.0.2.0/24"]
}

# ----------------------------------------------------------------------------
# Base de données MySQL Flexible Server
# ----------------------------------------------------------------------------
variable "mysql_admin_login" {
  description = "Login administrateur du serveur MySQL Flexible Server."
  type        = string
  default     = "blockhashadmin"
}

variable "mysql_sku_name" {
  description = "SKU du serveur MySQL Flexible Server (niveau de performance/coût)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "mysql_storage_size_gb" {
  description = "Taille du stockage alloué au serveur MySQL, en Go."
  type        = number
  default     = 20
}

variable "mysql_version" {
  description = "Version majeure de MySQL Flexible Server."
  type        = string
  default     = "8.0.21"
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
# Tags — appliqués uniformément à toutes les ressources pour la gouvernance
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
