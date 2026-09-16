##############################################################################
# modules/vm/main.tf
#
# Ce module provisionne la machine virtuelle Web de BlockHash :
#   - Interface réseau (NIC) rattachée au sous-réseau Web et à l'IP publique
#   - Machine virtuelle Linux Ubuntu 24.04 LTS (taille configurable)
#   - Une IDENTITE MANAGEE SYSTEME (Managed Identity), utilisée par
#     user_data.sh pour s'authentifier auprès d'Azure Key Vault et récupérer
#     les secrets (identifiants MySQL, webhook d'alerte) SANS qu'aucune
#     valeur secrète ne transite par le code Terraform ou le script cloud-init.
#   - Injection du script de provisioning user_data.sh via cloud-init (base64)
##############################################################################

# ----------------------------------------------------------------------------
# Interface réseau (NIC) de la VM Web.
# ----------------------------------------------------------------------------
resource "azurerm_network_interface" "web" {
  name                = "nic-web-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-web"
    subnet_id                     = var.web_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.public_ip_id
  }
}

# ----------------------------------------------------------------------------
# Association explicite du NSG à la NIC (double sécurité, en complément de
# l'association déjà faite au niveau du sous-réseau dans le module network).
# ----------------------------------------------------------------------------
resource "azurerm_network_interface_security_group_association" "web" {
  network_interface_id      = azurerm_network_interface.web.id
  network_security_group_id = var.nsg_id
}

# ----------------------------------------------------------------------------
# Rendu du template user_data.sh : injecte UNIQUEMENT des valeurs NON
# sensibles (nom du Key Vault, noms des secrets à récupérer, FQDN MySQL,
# nom de la base, adresse email d'alerte). Aucune valeur secrète n'est
# interpolée ici — user_data.sh les récupère lui-même à l'exécution via
# l'identité managée de la VM et l'API REST de Key Vault.
# ----------------------------------------------------------------------------
locals {
  user_data_rendered = templatefile("${path.module}/scripts/user_data.sh", {
    key_vault_name                    = var.key_vault_name
    mysql_admin_login_secret_name     = var.mysql_admin_login_secret_name
    mysql_admin_password_secret_name  = var.mysql_admin_password_secret_name
    alert_webhook_url_secret_name     = var.alert_webhook_url_secret_name
    mysql_fqdn                        = var.mysql_fqdn
    mysql_database_name               = var.mysql_database_name
    alert_email                       = var.alert_email
  })
}

# ----------------------------------------------------------------------------
# Machine Virtuelle Linux principale.
# Image : Ubuntu Server 24.04 LTS (Canonical), taille configurable via
# var.vm_size (Standard_B2s demandé par BlockHash : 2 vCPU / 4 Go RAM).
# ----------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "web" {
  name                = "vm-web-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [
    azurerm_network_interface.web.id,
  ]

  # Authentification par clé SSH générée par Terraform (module keyvault),
  # jamais par mot de passe.
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  disable_password_authentication = true

  # ----------------------------------------------------------------------
  # Identité managée SYSTEME : Azure crée et gère automatiquement une
  # identité Azure AD liée au cycle de vie de la VM. C'est cette identité
  # qui se voit accorder (au niveau racine, via azurerm_role_assignment)
  # le rôle "Key Vault Secrets User", permettant à user_data.sh d'obtenir
  # un jeton OAuth2 via le service de métadonnées IMDS et de lire les
  # secrets nécessaires, sans qu'aucun identifiant ne soit stocké sur la VM.
  # ----------------------------------------------------------------------
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "osdisk-web-${var.environment}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Script de provisioning cloud-init encodé en base64. Ne contient AUCUN
  # secret en clair (voir local.user_data_rendered ci-dessus).
  custom_data = base64encode(local.user_data_rendered)

  depends_on = [azurerm_network_interface_security_group_association.web]
}
