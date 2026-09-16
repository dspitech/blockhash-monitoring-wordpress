##############################################################################
# modules/vm/variables.tf
##############################################################################

variable "project_name" {
  description = "Nom court du projet, utilisé pour le nommage des ressources."
  type        = string
}

variable "environment" {
  description = "Environnement de déploiement (prod, staging, dev...)."
  type        = string
}

variable "location" {
  description = "Région Azure de déploiement."
  type        = string
}

variable "resource_group_name" {
  description = "Nom du Resource Group dans lequel créer la VM."
  type        = string
}

variable "web_subnet_id" {
  description = "ID du sous-réseau Web (snet-web) dans lequel rattacher la NIC."
  type        = string
}

variable "nsg_id" {
  description = "ID du Network Security Group à associer à la NIC."
  type        = string
}

variable "public_ip_id" {
  description = "ID de l'adresse IP publique à associer à la NIC."
  type        = string
}

variable "public_ip_address" {
  description = "Adresse IP publique de la VM (informatif)."
  type        = string
}

variable "vm_size" {
  description = "Taille (SKU) de la machine virtuelle Azure."
  type        = string
}

variable "admin_username" {
  description = "Nom d'utilisateur administrateur SSH de la VM."
  type        = string
}

variable "ssh_public_key" {
  description = "Clé publique SSH générée par Terraform (module keyvault) pour l'authentification sur la VM."
  type        = string
}

# ----------------------------------------------------------------------------
# Références Key Vault — UNIQUEMENT des noms/identifiants, jamais des
# valeurs secrètes. user_data.sh les utilise pour interroger Key Vault via
# l'identité managée de la VM et récupérer les vraies valeurs à l'exécution.
# ----------------------------------------------------------------------------
variable "key_vault_name" {
  description = "Nom du Key Vault Azure à interroger au démarrage de la VM."
  type        = string
}

variable "key_vault_uri" {
  description = "URI du Key Vault Azure (informatif)."
  type        = string
}

variable "mysql_admin_login_secret_name" {
  description = "Nom du secret Key Vault contenant le login administrateur MySQL."
  type        = string
}

variable "mysql_admin_password_secret_name" {
  description = "Nom du secret Key Vault contenant le mot de passe administrateur MySQL."
  type        = string
}

variable "alert_webhook_url_secret_name" {
  description = "Nom du secret Key Vault contenant l'URL de webhook d'alerte (chaîne vide = non configuré)."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Valeurs non sensibles (hostnames, noms) transmises directement.
# ----------------------------------------------------------------------------
variable "mysql_fqdn" {
  description = "FQDN privé du serveur MySQL Flexible Server (non sensible : un hostname seul ne permet aucune connexion)."
  type        = string
}

variable "mysql_database_name" {
  description = "Nom de la base de données WordPress."
  type        = string
}

variable "alert_email" {
  description = "Adresse email de destination des alertes (non sensible)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags Azure appliqués aux ressources du module."
  type        = map(string)
  default     = {}
}
