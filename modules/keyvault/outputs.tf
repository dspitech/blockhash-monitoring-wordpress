##############################################################################
# modules/keyvault/outputs.tf
##############################################################################

output "key_vault_id" {
  description = "ID de la ressource Key Vault (utilisé pour les role assignments)."
  value       = azurerm_key_vault.main.id
}

output "key_vault_name" {
  description = "Nom du Key Vault (utilisé par la VM à l'exécution pour construire l'URI des secrets)."
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "URI du Key Vault (https://<nom>.vault.azure.net/)."
  value       = azurerm_key_vault.main.vault_uri
}

# ----------------------------------------------------------------------------
# Clé publique SSH générée — NON sensible, transmise telle quelle à
# azurerm_linux_virtual_machine.admin_ssh_key dans le module vm.
# ----------------------------------------------------------------------------
output "ssh_public_key" {
  description = "Clé publique SSH générée par Terraform (format OpenSSH)."
  value       = tls_private_key.vm_ssh.public_key_openssh
}

# ----------------------------------------------------------------------------
# Clé privée SSH générée — sensible. Exposée en sortie de module pour être
# relayée par un output racine (pratique pour une récupération immédiate
# sans avoir à interroger Key Vault), en plus d'être stockée dans Key Vault
# pour une récupération ultérieure.
# ----------------------------------------------------------------------------
output "ssh_private_key" {
  description = "Clé privée SSH générée par Terraform (sensible)."
  value       = tls_private_key.vm_ssh.private_key_pem
  sensitive   = true
}

output "mysql_admin_password" {
  description = "Mot de passe administrateur MySQL généré (sensible) — transmis au module database."
  value       = random_password.mysql_admin_password.result
  sensitive   = true
}

# ----------------------------------------------------------------------------
# Noms des secrets Key Vault — non sensibles (ce sont des NOMS, pas des
# valeurs), transmis au module vm pour que user_data.sh sache QUOI
# demander à Key Vault au démarrage, sans jamais recevoir les valeurs
# elles-mêmes via Terraform/cloud-init.
# ----------------------------------------------------------------------------
output "mysql_admin_login_secret_name" {
  description = "Nom du secret Key Vault contenant le login administrateur MySQL."
  value       = azurerm_key_vault_secret.mysql_admin_login.name
}

output "mysql_admin_password_secret_name" {
  description = "Nom du secret Key Vault contenant le mot de passe administrateur MySQL."
  value       = azurerm_key_vault_secret.mysql_admin_password.name
}

output "alert_webhook_url_secret_name" {
  description = "Nom du secret Key Vault contenant l'URL de webhook d'alerte (chaîne vide si non créé)."
  value       = length(azurerm_key_vault_secret.alert_webhook_url) > 0 ? azurerm_key_vault_secret.alert_webhook_url[0].name : ""
}

output "dashboard_admin_password_secret_name" {
  description = "Nom du secret Key Vault contenant le mot de passe administrateur du dashboard."
  value       = azurerm_key_vault_secret.dashboard_admin_password.name
}
