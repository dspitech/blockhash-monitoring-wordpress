##############################################################################
# modules/database/main.tf
#
# Ce module provisionne la couche de persistance de BlockHash :
#   - Zone DNS Privée pour la résolution interne du serveur MySQL
#   - Lien entre la zone DNS privée et le VNet
#   - Serveur MySQL Flexible Server (injecté dans le VNet, SKU B_Standard_B1ms)
#   - Base de données applicative "wordpress" (utf8 / utf8_unicode_ci)
##############################################################################

# ----------------------------------------------------------------------------
# Zone DNS Privée : permet la résolution du FQDN du serveur MySQL
# (blockhash.private.mysql.database.azure.com) depuis l'intérieur du VNet,
# sans jamais exposer le serveur MySQL sur Internet.
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "mysql" {
  name                = "${var.project_name}.private.mysql.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# ----------------------------------------------------------------------------
# Lien entre la zone DNS privée et le Virtual Network : sans ce lien, la
# résolution DNS privée ne fonctionnerait pas depuis les VM du VNet.
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "vnet-link-mysql-${var.environment}"
  resource_group_name  = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# ----------------------------------------------------------------------------
# Serveur MySQL Flexible Server : instance managée par Azure, injectée
# directement dans le sous-réseau db_subnet_id (mode réseau privé "VNet
# Integrated"). Aucune exposition publique : accessible uniquement depuis
# les ressources du VNet (dont la VM Web).
#
# SKU B_Standard_B1ms = niveau "Burstable", économique, adapté à une charge
# WordPress modérée (1 vCore, 2 Go RAM).
# ----------------------------------------------------------------------------
resource "azurerm_mysql_flexible_server" "main" {
  name                = "mysql-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  # Identifiants administrateur — le mot de passe est généré aléatoirement
  # au niveau racine (random_password) et transmis via variable sensible.
  administrator_login    = var.mysql_admin_login
  administrator_password = var.mysql_admin_password

  # Intégration réseau privée : le serveur est injecté dans le sous-réseau
  # délégué "snet-db" et résolu via la zone DNS privée créée ci-dessus.
  delegated_subnet_id = var.db_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id

  sku_name   = var.mysql_sku_name
  version    = var.mysql_version
  storage {
    size_gb = var.mysql_storage_size_gb
    # Auto-grow désactivé par défaut pour garder un contrôle des coûts ;
    # peut être activé (true) en production selon les besoins de croissance.
    auto_grow_enabled = false
  }

  # Fenêtre de sauvegarde automatique gérée par Azure : rétention de 7 jours,
  # suffisante pour couvrir les besoins de restauration à court terme
  # (les sauvegardes long terme vers Blob Storage sont gérées séparément —
  # voir la roadmap "Sauvegarde & Plan de Reprise d'Activité").
  backup_retention_days = 7

  # Un seul serveur, pas de haute disponibilité zone-redondante pour
  # limiter les coûts (peut être activé via une variable dédiée si besoin).
  zone = "1"

  # La création dépend explicitement du lien DNS privé : Azure exige que
  # la zone DNS et son lien VNet existent AVANT la création du serveur
  # injecté dans le VNet, sous peine d'erreur de déploiement.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

# ----------------------------------------------------------------------------
# Base de données applicative "wordpress" : hébergera l'ensemble des tables
# WordPress (wp_posts, wp_users, wp_options, etc.).
# Charset utf8 / collation utf8_unicode_ci : compatibilité maximale avec le
# cœur de WordPress et ses plugins/thèmes.
# ----------------------------------------------------------------------------
resource "azurerm_mysql_flexible_database" "wordpress" {
  name                = "wordpress"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
}
