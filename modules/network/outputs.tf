##############################################################################
# modules/network/outputs.tf
##############################################################################

output "resource_group_name" {
  description = "Nom du Resource Group créé."
  value       = azurerm_resource_group.main.name
}

output "resource_group_location" {
  description = "Région du Resource Group créé."
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "ID du Virtual Network principal."
  value       = azurerm_virtual_network.main.id
}

output "web_subnet_id" {
  description = "ID du sous-réseau Web (snet-web)."
  value       = azurerm_subnet.web.id
}

output "nsg_id" {
  description = "ID du Network Security Group nsg-web."
  value       = azurerm_network_security_group.web.id
}

output "public_ip_id" {
  description = "ID de l'adresse IP publique statique de la VM Web."
  value       = azurerm_public_ip.web.id
}

output "public_ip_address" {
  description = "Adresse IP publique statique de la VM Web."
  value       = azurerm_public_ip.web.ip_address
}
