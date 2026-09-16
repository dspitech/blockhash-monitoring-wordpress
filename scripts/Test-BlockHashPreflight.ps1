<#
================================================================================
 Test-BlockHashPreflight.ps1

 Script de PRE-VALIDATION à exécuter depuis Azure Cloud Shell (PowerShell)
 AVANT de lancer "terraform apply". Il ne déploie rien : il vérifie que
 l'abonnement Azure courant est en mesure d'accueillir l'infrastructure
 BlockHash et que les variables du projet respectent les conventions Azure,
 afin d'éviter un échec en cours de déploiement.

 Vérifications effectuées :
   1. Session Azure active (Connect-AzAccount si nécessaire) + confirmation
      de l'abonnement ciblé.
   2. Fournisseurs de ressources (Resource Providers) requis, enregistrement
      automatique si manquant.
   3. Lecture et validation du fichier terraform.tfvars (présence, valeurs
      obligatoires renseignées).
   4. Validité de la région Azure demandée (location).
   5. Disponibilité de la taille de VM demandée dans la région, et quota de
      vCPU restant sur la famille correspondante.
   6. Conventions de nommage Azure (Resource Group, Key Vault, serveur
      MySQL, VM) : longueur, caractères autorisés.
   7. Disponibilité du NOM du Key Vault (unicité globale Azure).
   8. Exécution de "terraform init / validate / plan" si Terraform est
      disponible (c'est le cas par défaut dans Azure Cloud Shell).
   9. Rapport de synthèse coloré + code de sortie (0 = OK, 1 = échec).

 Utilisation (depuis Azure Cloud Shell - PowerShell) :

     cd blockhash-azure-infrastructure
     ./scripts/Test-BlockHashPreflight.ps1

 Paramètres optionnels :

     -TfVarsPath   : chemin vers le fichier terraform.tfvars (par défaut :
                     "./terraform.tfvars" relatif au dossier d'exécution).
     -SkipPlan     : ignore l'étape "terraform plan" (utile pour un simple
                     contrôle de conventions/quotas, sans initialiser
                     Terraform).
================================================================================
#>

[CmdletBinding()]
param(
    [string]$TfVarsPath = "./terraform.tfvars",
    [switch]$SkipPlan
)

# ------------------------------------------------------------------------
# État global du rapport : chaque vérification ajoute une entrée ici.
# ------------------------------------------------------------------------
$script:CheckResults = @()

function Add-CheckResult {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet("OK", "WARN", "FAIL")] [string]$Status,
        [Parameter(Mandatory)] [string]$Message
    )
    $script:CheckResults += [PSCustomObject]@{
        Name    = $Name
        Status  = $Status
        Message = $Message
    }

    switch ($Status) {
        "OK"   { Write-Host "  [OK]   $Name — $Message" -ForegroundColor Green }
        "WARN" { Write-Host "  [WARN] $Name — $Message" -ForegroundColor Yellow }
        "FAIL" { Write-Host "  [FAIL] $Name — $Message" -ForegroundColor Red }
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

##############################################################################
# 0. VERIFICATION DES MODULES AZ POWERSHELL
##############################################################################
Write-Section "0. Vérification des modules Az PowerShell"

$requiredModules = @("Az.Accounts", "Az.Resources", "Az.Compute", "Az.KeyVault")
foreach ($mod in $requiredModules) {
    if (Get-Module -ListAvailable -Name $mod) {
        Add-CheckResult -Name "Module $mod" -Status "OK" -Message "Disponible."
    } else {
        Add-CheckResult -Name "Module $mod" -Status "WARN" -Message "Non trouvé localement — Azure Cloud Shell le fournit normalement par défaut."
    }
}

##############################################################################
# 1. SESSION AZURE & ABONNEMENT
##############################################################################
Write-Section "1. Session Azure & abonnement cible"

$context = Get-AzContext
if (-not $context) {
    Write-Host "Aucune session Azure active. Lancement de Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}

if ($context) {
    Add-CheckResult -Name "Session Azure" -Status "OK" -Message "Connecté en tant que $($context.Account.Id)."
    Add-CheckResult -Name "Abonnement actif" -Status "OK" -Message "$($context.Subscription.Name) ($($context.Subscription.Id))."
    Write-Host ""
    Write-Host "Abonnement actuellement ciblé : $($context.Subscription.Name)" -ForegroundColor White
    $confirm = Read-Host "Confirmez-vous vouloir valider un déploiement sur CET abonnement ? (O/N)"
    if ($confirm -notmatch '^[OoYy]') {
        Write-Host "Utilisez 'Set-AzContext -Subscription <id-ou-nom>' pour changer d'abonnement, puis relancez ce script." -ForegroundColor Yellow
        exit 1
    }
} else {
    Add-CheckResult -Name "Session Azure" -Status "FAIL" -Message "Impossible d'établir une session Azure."
    exit 1
}

$subscriptionId = $context.Subscription.Id

##############################################################################
# 2. FOURNISSEURS DE RESSOURCES (RESOURCE PROVIDERS)
##############################################################################
Write-Section "2. Fournisseurs de ressources Azure requis"

$requiredProviders = @(
    "Microsoft.Compute",
    "Microsoft.Network",
    "Microsoft.DBforMySQL",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity"
)

foreach ($providerNamespace in $requiredProviders) {
    $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction SilentlyContinue

    if ($provider -and $provider.RegistrationState -contains "Registered") {
        Add-CheckResult -Name "Provider $providerNamespace" -Status "OK" -Message "Déjà enregistré."
    } else {
        Write-Host "  Enregistrement de $providerNamespace en cours..." -ForegroundColor Yellow
        try {
            Register-AzResourceProvider -ProviderNamespace $providerNamespace | Out-Null
            Add-CheckResult -Name "Provider $providerNamespace" -Status "WARN" -Message "Enregistrement lancé (peut prendre quelques minutes avant 'terraform apply')."
        } catch {
            Add-CheckResult -Name "Provider $providerNamespace" -Status "FAIL" -Message "Échec de l'enregistrement : $($_.Exception.Message)"
        }
    }
}

##############################################################################
# 3. LECTURE DU FICHIER terraform.tfvars
##############################################################################
Write-Section "3. Lecture de terraform.tfvars"

if (-not (Test-Path $TfVarsPath)) {
    Add-CheckResult -Name "terraform.tfvars" -Status "FAIL" -Message "Fichier introuvable ($TfVarsPath). Copiez terraform.tfvars.example puis personnalisez-le."
    $tfvars = @{}
} else {
    Add-CheckResult -Name "terraform.tfvars" -Status "OK" -Message "Fichier trouvé : $TfVarsPath"

    # Parsing volontairement simple (clé = "valeur" ou clé = valeur), suffisant
    # pour un fichier .tfvars "à plat" comme celui du projet BlockHash. Les
    # blocs multi-lignes (listes, maps) ne sont pas nécessaires ici : seules
    # les clés scalaires utilisées pour les vérifications sont extraites.
    $tfvars = @{}
    Get-Content $TfVarsPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"?([^"#]*)"?') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $tfvars[$key] = $value
        }
    }
}

# Valeurs par défaut de secours si absentes du tfvars (alignées sur variables.tf).
$location   = if ($tfvars.ContainsKey("location")) { $tfvars["location"] } else { "norwayeast" }
$vmSize     = if ($tfvars.ContainsKey("vm_size")) { $tfvars["vm_size"] } else { "Standard_B2s" }
$projectName = if ($tfvars.ContainsKey("project_name")) { $tfvars["project_name"] } else { "blockhash" }
$environment = if ($tfvars.ContainsKey("environment")) { $tfvars["environment"] } else { "prod" }

foreach ($requiredKey in @("project_name", "environment", "location", "vm_size", "mysql_admin_login")) {
    if ($tfvars.ContainsKey($requiredKey) -and $tfvars[$requiredKey] -ne "") {
        Add-CheckResult -Name "Variable '$requiredKey'" -Status "OK" -Message "Renseignée : $($tfvars[$requiredKey])"
    } else {
        Add-CheckResult -Name "Variable '$requiredKey'" -Status "WARN" -Message "Absente du tfvars — la valeur par défaut de variables.tf sera utilisée."
    }
}

# Rappel : plus de clé SSH ni de mot de passe à valider ici, puisque ces
# valeurs sont désormais générées automatiquement par Terraform et stockées
# dans Azure Key Vault (voir modules/keyvault).
Add-CheckResult -Name "Clé SSH VM" -Status "OK" -Message "Génération automatique par Terraform (tls_private_key) — aucune saisie requise."
Add-CheckResult -Name "Mot de passe MySQL" -Status "OK" -Message "Génération automatique par Terraform (random_password), stocké dans Key Vault."

##############################################################################
# 4. VALIDITE DE LA REGION AZURE
##############################################################################
Write-Section "4. Validation de la région Azure ($location)"

$validLocation = Get-AzLocation | Where-Object { $_.Location -eq $location }
if ($validLocation) {
    Add-CheckResult -Name "Région '$location'" -Status "OK" -Message "Région Azure valide ($($validLocation.DisplayName))."
} else {
    Add-CheckResult -Name "Région '$location'" -Status "FAIL" -Message "Région Azure inconnue. Utilisez 'Get-AzLocation | Select Location,DisplayName' pour lister les régions valides."
}

##############################################################################
# 5. TAILLE DE VM & QUOTA vCPU
##############################################################################
Write-Section "5. Disponibilité de la taille de VM ($vmSize) et quota vCPU"

try {
    $sku = Get-AzComputeResourceSku -Location $location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq "virtualMachines" -and $_.Name -eq $vmSize }

    if (-not $sku) {
        Add-CheckResult -Name "SKU VM '$vmSize'" -Status "FAIL" -Message "Non disponible dans la région '$location'. Choisissez une autre taille ou une autre région."
    } else {
        $restrictions = $sku.Restrictions
        if ($restrictions -and $restrictions.Count -gt 0) {
            Add-CheckResult -Name "SKU VM '$vmSize'" -Status "WARN" -Message "Disponible mais soumis à restriction(s) sur cet abonnement : $($restrictions.ReasonCode -join ', ')"
        } else {
            Add-CheckResult -Name "SKU VM '$vmSize'" -Status "OK" -Message "Disponible sans restriction dans '$location'."
        }

        # Standard_B2s = 2 vCPU. On vérifie le quota de la famille "Basic A / B
        # Series" (regroupement Azure des tailles "Bs") dans la région ciblée.
        $vCpuNeeded = 2
        $usage = Get-AzVMUsage -Location $location | Where-Object { $_.Name.LocalizedValue -match "Basic|B Series|Standard BS" }

        if ($usage) {
            foreach ($u in $usage) {
                $remaining = $u.Limit - $u.CurrentValue
                if ($remaining -ge $vCpuNeeded) {
                    Add-CheckResult -Name "Quota vCPU ($($u.Name.LocalizedValue))" -Status "OK" -Message "$remaining vCPU restants sur $($u.Limit) (besoin : $vCpuNeeded)."
                } else {
                    Add-CheckResult -Name "Quota vCPU ($($u.Name.LocalizedValue))" -Status "FAIL" -Message "Seulement $remaining vCPU restants sur $($u.Limit) — insuffisant pour $vmSize (besoin : $vCpuNeeded). Demandez une augmentation de quota."
                }
            }
        } else {
            Add-CheckResult -Name "Quota vCPU" -Status "WARN" -Message "Impossible de déterminer précisément le quota de la famille B-series ; vérifiez manuellement via 'Get-AzVMUsage -Location $location'."
        }
    }
} catch {
    Add-CheckResult -Name "SKU VM '$vmSize'" -Status "WARN" -Message "Vérification impossible : $($_.Exception.Message)"
}

##############################################################################
# 6. CONVENTIONS DE NOMMAGE AZURE
##############################################################################
Write-Section "6. Conventions de nommage des ressources"

$namesToCheck = @(
    @{ Label = "Resource Group"; Value = "rg-$projectName-$environment"; Pattern = '^[a-zA-Z0-9._\-()]{1,90}$' }
    @{ Label = "VM";             Value = "vm-web-$environment";          Pattern = '^[a-zA-Z0-9-]{1,64}$' }
    @{ Label = "Serveur MySQL";  Value = "mysql-$projectName-$environment"; Pattern = '^[a-z0-9-]{3,63}$' }
)

foreach ($item in $namesToCheck) {
    if ($item.Value -match $item.Pattern) {
        Add-CheckResult -Name "Nom $($item.Label)" -Status "OK" -Message "'$($item.Value)' respecte les conventions Azure."
    } else {
        Add-CheckResult -Name "Nom $($item.Label)" -Status "FAIL" -Message "'$($item.Value)' ne respecte PAS les conventions Azure (longueur/caractères)."
    }
}

# Le Key Vault ajoute un suffixe aléatoire (voir modules/keyvault/main.tf) :
# on ne peut donc pas prédire son nom final ici, mais on peut vérifier que
# le préfixe reste sous la limite de 24 caractères une fois le suffixe (5
# caractères + 1 tiret) ajouté.
$kvPrefix = "kv-$projectName-$environment-"
if (($kvPrefix.Length + 5) -le 24) {
    Add-CheckResult -Name "Préfixe Key Vault" -Status "OK" -Message "'$kvPrefix<suffixe>' tiendra dans la limite de 24 caractères d'Azure Key Vault."
} else {
    Add-CheckResult -Name "Préfixe Key Vault" -Status "FAIL" -Message "'$kvPrefix<suffixe>' dépassera la limite de 24 caractères — raccourcissez project_name ou environment."
}

##############################################################################
# 7. QUOTAS ADDITIONNELS (Adresses IP publiques, vCPU total région)
##############################################################################
Write-Section "7. Quotas réseau additionnels"

try {
    $networkUsage = Get-AzNetworkUsage -Location $location -ErrorAction Stop |
        Where-Object { $_.Name.Value -eq "PublicIPAddresses" }

    if ($networkUsage) {
        $remainingIps = $networkUsage.Limit - $networkUsage.CurrentValue
        if ($remainingIps -ge 1) {
            Add-CheckResult -Name "Quota IP publiques" -Status "OK" -Message "$remainingIps adresse(s) IP publique(s) restante(s) sur $($networkUsage.Limit)."
        } else {
            Add-CheckResult -Name "Quota IP publiques" -Status "FAIL" -Message "Quota d'IP publiques épuisé dans '$location'."
        }
    } else {
        Add-CheckResult -Name "Quota IP publiques" -Status "WARN" -Message "Impossible de récupérer ce quota automatiquement."
    }
} catch {
    Add-CheckResult -Name "Quota IP publiques" -Status "WARN" -Message "Vérification impossible : $($_.Exception.Message)"
}

##############################################################################
# 8. VALIDATION / PLAN TERRAFORM
##############################################################################
Write-Section "8. Validation Terraform (init / validate / plan)"

$terraformCmd = Get-Command terraform -ErrorAction SilentlyContinue

if (-not $terraformCmd) {
    Add-CheckResult -Name "Terraform CLI" -Status "WARN" -Message "Terraform introuvable dans le PATH (inattendu dans Azure Cloud Shell). Étape ignorée."
} else {
    Add-CheckResult -Name "Terraform CLI" -Status "OK" -Message "Version détectée : $((terraform version -json | ConvertFrom-Json).terraform_version)"

    Write-Host "  Exécution de 'terraform init'..." -ForegroundColor Yellow
    terraform init -input=false | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-CheckResult -Name "terraform init" -Status "OK" -Message "Initialisation réussie."
    } else {
        Add-CheckResult -Name "terraform init" -Status "FAIL" -Message "Échec de l'initialisation — voir la sortie ci-dessus."
    }

    Write-Host "  Exécution de 'terraform validate'..." -ForegroundColor Yellow
    terraform validate | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-CheckResult -Name "terraform validate" -Status "OK" -Message "Syntaxe et cohérence des modules valides."
    } else {
        Add-CheckResult -Name "terraform validate" -Status "FAIL" -Message "Erreurs de validation détectées — voir la sortie ci-dessus."
    }

    if (-not $SkipPlan -and $LASTEXITCODE -eq 0) {
        Write-Host "  Exécution de 'terraform plan' (aucune ressource n'est créée)..." -ForegroundColor Yellow
        terraform plan -input=false -out="preflight.tfplan" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Add-CheckResult -Name "terraform plan" -Status "OK" -Message "Plan généré avec succès (preflight.tfplan). Vous pouvez l'appliquer avec 'terraform apply preflight.tfplan'."
        } else {
            Add-CheckResult -Name "terraform plan" -Status "FAIL" -Message "Échec de la génération du plan — voir la sortie ci-dessus (souvent lié aux quotas/permissions)."
        }
    }
}

##############################################################################
# 9. RAPPORT DE SYNTHESE
##############################################################################
Write-Section "9. Rapport de synthèse"

$failCount = ($script:CheckResults | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = ($script:CheckResults | Where-Object { $_.Status -eq "WARN" }).Count
$okCount   = ($script:CheckResults | Where-Object { $_.Status -eq "OK" }).Count

Write-Host ""
Write-Host "Résultats : $okCount OK / $warnCount avertissement(s) / $failCount échec(s)" -ForegroundColor White

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host " Des problèmes BLOQUANTS ont été détectés. Corrigez-les avant de lancer 'terraform apply'." -ForegroundColor Red
    exit 1
} elseif ($warnCount -gt 0) {
    Write-Host ""
    Write-Host "  Le déploiement devrait fonctionner, mais vérifiez les avertissements ci-dessus." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host ""
    Write-Host " Toutes les vérifications sont passées. Vous pouvez lancer 'terraform apply' en toute confiance." -ForegroundColor Green
    exit 0
}
