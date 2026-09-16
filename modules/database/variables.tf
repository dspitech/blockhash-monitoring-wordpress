##############################################################################
# modules/database/variables.tf
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
  description = "Nom du Resource Group dans lequel créer les ressources database."
  type        = string
}

variable "vnet_id" {
  description = "ID du Virtual Network auquel lier la zone DNS privée."
  type        = string
}

variable "db_subnet_id" {
  description = "ID du sous-réseau délégué MySQL (snet-db) dans lequel injecter le serveur."
  type        = string
}

variable "mysql_admin_login" {
  description = "Login administrateur du serveur MySQL."
  type        = string
}

variable "mysql_admin_password" {
  description = "Mot de passe administrateur du serveur MySQL (sensible)."
  type        = string
  sensitive   = true
}

variable "mysql_sku_name" {
  description = "SKU du serveur MySQL Flexible Server."
  type        = string
}

variable "mysql_storage_size_gb" {
  description = "Taille du stockage MySQL en Go."
  type        = number
}

variable "mysql_version" {
  description = "Version majeure de MySQL."
  type        = string
}

variable "tags" {
  description = "Tags Azure appliqués aux ressources du module."
  type        = map(string)
  default     = {}
}
