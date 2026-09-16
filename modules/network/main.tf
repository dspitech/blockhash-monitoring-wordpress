##############################################################################
# modules/network/main.tf
#
# Ce module provisionne toute la fondation réseau de BlockHash :
#   - Resource Group
#   - Virtual Network (10.0.0.0/16)
#   - Sous-réseau Web (10.0.1.0/24)
#   - Sous-réseau Database délégué à MySQL Flexible Server (10.0.2.0/24)
#   - Network Security Group (HTTP 80, SSH 22, WebSocket Dashboard 3000)
#   - Adresse IP publique statique pour la VM Web
##############################################################################

# ----------------------------------------------------------------------------
# Resource Group : conteneur logique regroupant toutes les ressources Azure
# de l'infrastructure BlockHash. Nommage : rg-<projet>-<environnement>.
# ----------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = var.tags
}

# ----------------------------------------------------------------------------
# Virtual Network principal : englobe l'ensemble des sous-réseaux de
# l'infrastructure. Plage CIDR globale : 10.0.0.0/16.
# ----------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project_name}-${var.environment}"
  address_space       = var.vnet_address_space
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# ----------------------------------------------------------------------------
# Sous-réseau Web : héberge la VM Nginx/PHP/WordPress/Dashboard Node.js.
# Aucune délégation particulière : c'est un sous-réseau standard.
# ----------------------------------------------------------------------------
resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.web_subnet_prefix
}

# ----------------------------------------------------------------------------
# Sous-réseau Database : DOIT être délégué au service
# "Microsoft.DBforMySQL/flexibleServers" pour permettre l'injection VNet
# du serveur MySQL Flexible Server (intégration réseau privée native Azure).
# ----------------------------------------------------------------------------
resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.db_subnet_prefix

  # Bloc de délégation obligatoire pour MySQL Flexible Server injecté VNet.
  delegation {
    name = "mysql-flexible-server-delegation"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# ----------------------------------------------------------------------------
# Adresse IP publique statique attachée à la VM Web.
# "Static" garantit que l'IP ne change pas entre les redémarrages de la VM.
# SKU "Standard" requis pour être compatible avec les VM modernes et les NSG.
# ----------------------------------------------------------------------------
resource "azurerm_public_ip" "web" {
  name                = "pip-web-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ----------------------------------------------------------------------------
# Network Security Group (NSG) : pare-feu applicatif au niveau du sous-réseau
# Web. Autorise uniquement les flux entrants strictement nécessaires :
#   - 22   (SSH)                : administration de la VM
#   - 80   (HTTP)                : trafic WordPress/Nginx
#   - 3000 (WebSocket Dashboard) : flux temps réel du dashboard de monitoring
# Tout le reste du trafic entrant est implicitement refusé (règle Azure
# "DenyAllInBound" par défaut, priorité 65500).
# ----------------------------------------------------------------------------
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # Règle SSH — administration distante de la VM.
  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Règle HTTP — accès public au site WordPress.
  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Règle WebSocket Dashboard — flux temps réel Socket.io (port 3000).
  security_rule {
    name                       = "Allow-Dashboard-WebSocket"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# ----------------------------------------------------------------------------
# Association du NSG au sous-réseau Web : applique les règles de sécurité
# définies ci-dessus à toutes les ressources (NIC) présentes dans snet-web.
# ----------------------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}
