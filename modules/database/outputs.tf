##############################################################################
# modules/database/outputs.tf
##############################################################################

output "mysql_server_id" {
  description = "ID du serveur MySQL Flexible Server."
  value       = azurerm_mysql_flexible_server.main.id
}

output "mysql_server_fqdn" {
  description = "FQDN privé du serveur MySQL (résolution interne au VNet uniquement)."
  value       = azurerm_mysql_flexible_server.main.fqdn
}

output "mysql_database_name" {
  description = "Nom de la base de données applicative WordPress."
  value       = azurerm_mysql_flexible_database.wordpress.name
}

output "private_dns_zone_id" {
  description = "ID de la zone DNS privée MySQL."
  value       = azurerm_private_dns_zone.mysql.id
}
