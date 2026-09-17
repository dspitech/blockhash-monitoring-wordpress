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
# sensibles (nom du Key Vault, noms des secrets à récupérer, nom de la base
# MySQL locale, adresse email d'alerte). Aucune valeur secrète n'est
# interpolée ici — user_data.sh les récupère lui-même à l'exécution via
# l'identité managée de la VM et l'API REST de Key Vault.
#
# NOTE (v2) : il n'y a plus de "mysql_fqdn" à transmettre — MySQL est
# installé et écoute localement sur la VM (127.0.0.1:3306).
# ----------------------------------------------------------------------------
locals {
  user_data_rendered = templatefile("${path.module}/scripts/user_data.sh", {
    key_vault_name                    = var.key_vault_name
    mysql_admin_login_secret_name     = var.mysql_admin_login_secret_name
    mysql_admin_password_secret_name  = var.mysql_admin_password_secret_name
    alert_webhook_url_secret_name     = var.alert_webhook_url_secret_name
    dashboard_admin_password_secret_name = var.dashboard_admin_password_secret_name
    dashboard_admin_username          = var.dashboard_admin_username
    mysql_database_name               = var.mysql_database_name
    alert_email                       = var.alert_email
  })

  # --------------------------------------------------------------------
  # CONTOURNEMENT DE LA LIMITE AZURE "custom_data" (87 380 caractères en
  # base64, soit ~65 535 caractères en clair) :
  #
  # Le dashboard entreprise (backend Node.js + frontend HTML/CSS/JS
  # abondamment commentés) fait grossir user_data.sh bien au-delà de cette
  # limite (~83 000 caractères en clair, ~110 000 une fois encodé en
  # base64 — Azure refuse la création de la VM avec l'erreur
  # "InvalidParameter: Custom data ... maximum length of 87380 characters").
  #
  # Solution : le script complet est compressé en gzip puis encodé en
  # base64 via la fonction native base64gzip() de Terraform (résultat
  # ~30 000 caractères, uniquement composés de l'alphabet base64 standard
  # A-Za-z0-9+/=, donc sans aucun risque de collision avec la syntaxe
  # d'interpolation Terraform ${...}). C'est ce blob compressé qui est
  # embarqué dans un très court script "bootstrap", lequel est LUI
  # effectivement transmis à Azure via custom_data : il se contente de
  # décompresser le script complet sur la VM puis de l'exécuter.
  # --------------------------------------------------------------------
  user_data_gzip_b64 = base64gzip(local.user_data_rendered)

  bootstrap_script = <<-EOT
    #!/bin/bash
    # Bootstrap cloud-init minimal : décompresse et exécute le script de
    # provisioning complet (voir modules/vm/scripts/user_data.sh), stocké
    # ci-dessous sous forme compressée pour respecter la limite Azure de
    # 87 380 caractères sur "custom_data".
    set -euo pipefail
    exec > >(tee -a /var/log/user-data-bootstrap.log) 2>&1
    echo ">>> [BlockHash] Bootstrap : décompression du script de provisioning..."

    mkdir -p /opt/blockhash

    cat > /opt/blockhash/provision.sh.gz.b64 << 'BLOB_EOF'
    ${local.user_data_gzip_b64}
    BLOB_EOF

    base64 -d /opt/blockhash/provision.sh.gz.b64 | gunzip > /opt/blockhash/provision.sh
    chmod +x /opt/blockhash/provision.sh
    rm -f /opt/blockhash/provision.sh.gz.b64

    echo ">>> [BlockHash] Bootstrap terminé, lancement du provisioning complet..."
    /opt/blockhash/provision.sh
    EOT
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

  # Script de provisioning transmis via un bootstrap compressé (voir
  # local.bootstrap_script ci-dessus) — contourne la limite Azure de
  # 87 380 caractères sur "custom_data". Le script complet ne contient
  # AUCUN secret en clair (voir local.user_data_rendered).
  custom_data = base64encode(local.bootstrap_script)

  depends_on = [azurerm_network_interface_security_group_association.web]
}
