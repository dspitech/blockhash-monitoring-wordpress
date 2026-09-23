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

# ----------------------------------------------------------------------------
# ETAPE 1 (sécurité réseau) : au lieu d'ouvrir SSH à "*" (0.0.0.0/0), on le
# restreint à une IP ou plage source précise (ex. l'IP de la box internet de
# l'administrateur). Gratuit : c'est une simple règle NSG, pas de ressource
# Azure supplémentaire. Par défaut "*" pour ne pas casser un déploiement
# existant tant que la variable n'est pas positionnée dans terraform.tfvars,
# mais il est FORTEMENT recommandé de la renseigner.
# ----------------------------------------------------------------------------
variable "ssh_allowed_source_ip" {
  description = "Adresse IP (ou plage CIDR) autorisée à se connecter en SSH (port 22). A restreindre a votre IP publique (ex. \"90.12.34.56/32\") plutot que de laisser \"*\"."
  type        = string
  default     = "*"
}
