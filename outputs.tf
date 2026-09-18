##############################################################################
# outputs.tf - Sorties exposees au niveau racine apres "terraform apply"
##############################################################################

output "vm_public_ip_address" {
  description = "Adresse IP publique statique de la VM Web BlockHash."
  value       = module.network.public_ip_address
}

output "wordpress_url" {
  description = "URL d'acces au site WordPress."
  value       = "http://${module.network.public_ip_address}/"
}

output "dashboard_url" {
  description = "URL d'acces au dashboard de monitoring temps reel (page de connexion)."
  value       = "http://${module.network.public_ip_address}/dashboard/login"
}

output "ssh_connection_command" {
  description = "Commande SSH pour se connecter a la VM Web (necessite la cle privee, voir vm_ssh_private_key)."
  value       = "ssh -i blockhash_vm_key.pem ${var.vm_admin_username}@${module.network.public_ip_address}"
}

output "resource_group_name" {
  description = "Nom du Resource Group Azure contenant toutes les ressources BlockHash."
  value       = module.network.resource_group_name
}

# ----------------------------------------------------------------------------
# Key Vault - le mot de passe MySQL et le webhook d'alerte, eux, ne sont
# jamais exposes en clair via un output : ils doivent etre recuperes
# directement depuis Key Vault :
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
# Cle privee SSH generee automatiquement par Terraform - sensible. Pour la
# recuperer et vous connecter a la VM :
#
#   terraform output -raw vm_ssh_private_key > blockhash_vm_key.pem
#   chmod 600 blockhash_vm_key.pem
#   ssh -i blockhash_vm_key.pem <user>@<ip>
#
# Cette cle est egalement stockee dans Key Vault (secret
# "vm-ssh-private-key") pour une recuperation ulterieure par toute personne
# autorisee, sans avoir a re-executer Terraform.
# ----------------------------------------------------------------------------
output "vm_ssh_private_key" {
  description = "Cle privee SSH generee par Terraform pour se connecter a la VM (sensible)."
  value       = module.keyvault.ssh_private_key
  sensitive   = true
}

# ----------------------------------------------------------------------------
# Identifiants de connexion au dashboard de monitoring - places en dernier
# volontairement : ce sont les toutes dernieres informations affichees apres
# "terraform apply", pratiques a copier immediatement pour se connecter a
# l'interface web. Le mot de passe est marque "sensible" (non affiche par
# defaut dans le recapitulatif de sortie de "terraform apply", uniquement
# via "terraform output -raw dashboard_admin_password").
# ----------------------------------------------------------------------------
output "dashboard_admin_username" {
  description = "Nom d'utilisateur pour se connecter au dashboard de monitoring."
  value       = var.dashboard_admin_username
}

output "dashboard_admin_password" {
  description = "Mot de passe du dashboard de monitoring, genere par Terraform (sensible). Recuperer avec : terraform output -raw dashboard_admin_password"
  value       = module.keyvault.dashboard_admin_password
  sensitive   = true
}
