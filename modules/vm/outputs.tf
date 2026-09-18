##############################################################################
# modules/vm/outputs.tf
##############################################################################

output "vm_id" {
  description = "ID de la machine virtuelle Web."
  value       = azurerm_linux_virtual_machine.web.id
}

output "vm_name" {
  description = "Nom de la machine virtuelle Web."
  value       = azurerm_linux_virtual_machine.web.name
}

output "nic_id" {
  description = "ID de l'interface réseau de la VM Web."
  value       = azurerm_network_interface.web.id
}

output "vm_private_ip_address" {
  description = "Adresse IP privée de la VM Web (au sein du VNet)."
  value       = azurerm_network_interface.web.private_ip_address
}

# ----------------------------------------------------------------------------
# Principal ID de l'identité managée système de la VM - utilisé au niveau
# racine pour lui accorder le rôle "Key Vault Secrets User" sur le Key Vault
# (azurerm_role_assignment.vm_keyvault_secrets_user dans main.tf).
# ----------------------------------------------------------------------------
output "principal_id" {
  description = "Object ID de l'identité managée système (SystemAssigned) de la VM Web."
  value       = azurerm_linux_virtual_machine.web.identity[0].principal_id
}
