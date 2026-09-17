##############################################################################
# modules/network/variables.tf
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

variable "vnet_address_space" {
  description = "Plage CIDR globale du Virtual Network."
  type        = list(string)
}

variable "web_subnet_prefix" {
  description = "Plage CIDR du sous-réseau Web."
  type        = list(string)
}

variable "tags" {
  description = "Tags Azure appliqués aux ressources du module."
  type        = map(string)
  default     = {}
}
