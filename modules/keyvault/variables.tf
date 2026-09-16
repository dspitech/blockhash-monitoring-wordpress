##############################################################################
# modules/keyvault/variables.tf
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
  description = "Nom du Resource Group dans lequel créer le Key Vault."
  type        = string
}

variable "mysql_admin_login" {
  description = "Login administrateur MySQL à stocker dans Key Vault."
  type        = string
}

variable "alert_webhook_url" {
  description = "URL de webhook Discord/Slack à stocker dans Key Vault (optionnel, chaîne vide = non créé)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "purge_protection_enabled" {
  description = <<-EOT
    Active la protection contre la purge définitive du Key Vault. Recommandé
    à "true" en production réelle ; peut être laissé à "false" en
    environnement de test/démo pour permettre des cycles destroy/apply
    répétés sans période d'attente de 7 jours avant réutilisation du nom.
  EOT
  type    = bool
  default = false
}

variable "tags" {
  description = "Tags Azure appliqués aux ressources du module."
  type        = map(string)
  default     = {}
}
