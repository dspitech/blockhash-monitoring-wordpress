##############################################################################
# outputs.tf — Sorties exposées au niveau racine après "terraform apply"
##############################################################################

output "vm_public_ip_address" {
  description = "Adresse IP publique statique de la VM Web BlockHash."
  value       = module.network.public_ip_address
}

output "wordpress_url" {
  description = "URL d'accès au site WordPress."
  value       = "http://${module.network.public_ip_address}/"
}

output "dashboard_url" {
  description = "URL d'accès au dashboard de monitoring temps réel (page de connexion)."
  value       = "http://${module.network.public_ip_address}/dashboard/login"
}

output "dashboard_admin_username" {
  description = "Nom d'utilisateur pour se connecter au dashboard (mot de passe : voir Key Vault, secret 'dashboard-admin-password')."
  value       = var.dashboard_admin_username
}

output "ssh_connection_command" {
  description = "Commande SSH pour se connecter à la VM Web (nécessite la clé privée, voir vm_ssh_private_key)."
  value       = "ssh -i blockhash_vm_key.pem ${var.vm_admin_username}@${module.network.public_ip_address}"
}

output "resource_group_name" {
  description = "Nom du Resource Group Azure contenant toutes les ressources BlockHash."
  value       = module.network.resource_group_name
}

# ----------------------------------------------------------------------------
# Key Vault — aucune valeur secrète n'est exposée en clair ici (hormis la
# clé privée SSH ci-dessous, indispensable pour la première connexion et
# volontairement marquée "sensitive"). Le mot de passe MySQL et le webhook
# d'alerte doivent être récupérés directement depuis Key Vault :
#
#   az keyvault secret show --vault-name <key_vault_name> \
#       --name mysql-admin-password --query value -o tsv
# ----------------------------------------------------------------------------
output "key_vault_name" {
  description = "Nom du Key Vault Azure contenant tous les secrets BlockHash."
  value       = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  description = "URI du Key Vault Azure (https://<nom>.vault.azure.net/)."
  value       = module.keyvault.key_vault_uri
}

# ----------------------------------------------------------------------------
# Clé privée SSH générée automatiquement par Terraform — sensible. Pour la
# récupérer et vous connecter à la VM :
#
#   terraform output -raw vm_ssh_private_key > blockhash_vm_key.pem
#   chmod 600 blockhash_vm_key.pem
#   ssh -i blockhash_vm_key.pem <user>@<ip>
#
# Cette clé est également stockée dans Key Vault (secret
# "vm-ssh-private-key") pour une récupération ultérieure par toute personne
# autorisée, sans avoir à ré-exécuter Terraform.
# ----------------------------------------------------------------------------
output "vm_ssh_private_key" {
  description = "Clé privée SSH générée par Terraform pour se connecter à la VM (sensible)."
  value       = module.keyvault.ssh_private_key
  sensitive   = true
}
