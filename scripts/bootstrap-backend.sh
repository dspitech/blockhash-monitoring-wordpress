#!/bin/bash
##############################################################################
# bootstrap-backend.sh - ETAPE 5 : crée UNE SEULE FOIS l'infrastructure de
# stockage du "state" Terraform distant (backend "azurerm").
#
# Pourquoi : le state Terraform contient tout, y compris des références aux
# secrets (mots de passe MySQL/dashboard, clé SSH privée si jamais exportée)
# et l'historique complet des ressources. Le laisser en local
# (terraform.tfstate) sur un poste de dev est un risque de sécurité ET de
# perte de données (pas de sauvegarde, pas de verrouillage en cas de travail
# à plusieurs).
#
# Coût : un Storage Account "Standard_LRS" contenant un fichier de quelques
# kilo-octets coûte quelques centimes par mois - couvert très largement par
# le crédit Azure for Students, ou par le quota gratuit de stockage Blob
# (5 Go offerts pendant 12 mois sur un nouveau compte Azure).
#
# Ce script utilise volontairement Azure CLI (et non Terraform) : c'est le
# classique problème de "l'oeuf et la poule" - on ne peut pas stocker le
# state du backend DANS le backend qu'on est en train de créer.
#
# Usage :
#   chmod +x scripts/bootstrap-backend.sh
#   ./scripts/bootstrap-backend.sh
#
# Puis reportez les valeurs affichées dans le bloc "backend \"azurerm\" {}"
# (commenté) en haut de main.tf, et lancez :
#   terraform init -migrate-state
##############################################################################
set -euo pipefail

# Personnalisez si besoin (doivent rester cohérents avec ce que vous
# utiliserez dans le bloc backend de main.tf).
RESOURCE_GROUP="rg-blockhash-tfstate"
LOCATION="norwayeast"
# Le nom du Storage Account doit être UNIQUE AU MONDE (DNS), 3-24
# caractères, minuscules et chiffres uniquement. Adaptez le suffixe si le
# nom est déjà pris.
STORAGE_ACCOUNT="stblockhashtfstate$RANDOM"
CONTAINER_NAME="tfstate"

echo ">>> Vérification de la connexion Azure CLI..."
az account show >/dev/null || { echo "Lancez d'abord: az login"; exit 1; }

echo ">>> Création du Resource Group dédié '$RESOURCE_GROUP'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo ">>> Création du Storage Account '$STORAGE_ACCOUNT' (Standard_LRS, HTTPS uniquement)..."
az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --min-tls-version TLS1_2 \
    --https-only true \
    --allow-blob-public-access false \
    --output none

echo ">>> Activation du versioning des blobs (récupération possible d'un state écrasé par erreur)..."
az storage account blob-service-properties update \
    --account-name "$STORAGE_ACCOUNT" \
    --enable-versioning true \
    --output none

echo ">>> Création du container '$CONTAINER_NAME'..."
az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --output none

cat <<EOF

============================================================================
 Backend Terraform distant prêt. Reportez ces valeurs dans main.tf :

  backend "azurerm" {
    resource_group_name  = "$RESOURCE_GROUP"
    storage_account_name = "$STORAGE_ACCOUNT"
    container_name        = "$CONTAINER_NAME"
    key                   = "blockhash.prod.tfstate"
  }

 Puis lancez :
   terraform init -migrate-state
============================================================================
EOF
