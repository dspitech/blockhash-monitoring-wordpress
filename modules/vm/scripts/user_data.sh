#!/bin/bash
##############################################################################
# user_data.sh - Script de provisioning cloud-init exécuté au premier
# démarrage de la VM Web BlockHash (Ubuntu 24.04 LTS).
#
# GESTION DES SECRETS : ce script ne contient AUCUN mot de passe, clé SSH ou
# identifiant de base de données en clair. Les seules valeurs interpolées
# par Terraform (templatefile) ci-dessous sont NON SENSIBLES :
#   - key_vault_name                        : nom du Key Vault à interroger
#   - mysql_admin_login_secret_name         : NOM du secret (pas sa valeur)
#   - mysql_admin_password_secret_name      : NOM du secret (pas sa valeur)
#   - alert_webhook_url_secret_name         : NOM du secret (pas sa valeur)
#   - dashboard_admin_password_secret_name  : NOM du secret (pas sa valeur)
#   - dashboard_admin_username              : nom d'utilisateur du dashboard
#   - mysql_database_name                   : nom de la base ("wordpress")
#   - alert_email                           : adresse email de destination
#
# Les VALEURS secrètes elles-mêmes (mots de passe MySQL/dashboard, webhook)
# sont récupérées UNIQUEMENT à l'exécution, depuis Azure Key Vault, en
# utilisant l'identité managée système (Managed Identity) de la VM via le
# service de métadonnées IMDS (http://169.254.169.254). Elles ne transitent
# jamais par le state Terraform sous cette forme, ni par un fichier de
# configuration en clair accessible à un utilisateur non privilégié sur la VM.
#
# ARCHITECTURE MySQL (v2) : Azure Database for MySQL Flexible Server a été
# abandonné (restriction "ProvisionNotSupportedForRegion" constatée sur
# l'abonnement Azure for Students, indépendante de la région). MySQL Server
# 8.x est donc installé et configuré DIRECTEMENT SUR CETTE VM (127.0.0.1),
# et WordPress s'y connecte en local plutôt qu'à un serveur managé distant.
#
# DASHBOARD ENTREPRISE (v3) : le dashboard de monitoring passe d'un simple
# tableau de bord en lecture libre à une véritable application interne :
#   - Authentification par session (page de connexion, cookie signé),
#     identifiants stockés dans Key Vault.
#   - Persistance de l'historique des métriques sur disque (fichiers JSON
#     Lines dans /var/lib/blockhash/), avec sélecteur de plage temporelle
#     (1h / 6h / 24h / 7j) au lieu d'un simple tampon mémoire perdu au
#     rechargement de la page.
#   - KPIs calculés : disponibilité (uptime) 24h/7j, latence moyenne
#     ($request_time Nginx), volume de requêtes du jour.
#   - Analyse des logs Nginx en direct : répartition des codes HTTP,
#     top endpoints, top adresses IP.
#   - Panneau de santé des services système (Nginx, PHP-FPM, MySQL,
#     dashboard Node.js lui-même).
#   - Journal d'incidents persistant, alimenté par monitor.sh, avec
#     notifications "toast" en direct côté navigateur.
#   - Bascule thème clair/sombre.
#
# Étapes réalisées :
#    1. Mise à jour système & installation des dépendances (dont jq, mysql-server)
#    2. Mise en place de l'accès Key Vault (config + script kv-get-secret.sh)
#    3. Installation et configuration de MySQL Server LOCAL (base + utilisateur)
#    4. Configuration Nginx (WordPress + proxy dashboard/API/WebSocket + logs enrichis)
#    5. Déploiement et configuration de WordPress (connexion à MySQL local)
#    6. Configuration de l'authentification du dashboard (Key Vault)
#    7. Script de monitoring enrichi (monitor.sh) + scripts de test (5xx, CPU, latence, MySQL)
#    8. Planification Cron du monitoring (toutes les 5 minutes)
#    9. Backend Node.js WebSockets + API + auth (dashboard/server.js) piloté par pm2
#   10. Frontend Dashboard entreprise (dashboard/index.html + login.html)
##############################################################################

set -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo ">>> [BlockHash] Démarrage du provisioning $(date)"

##############################################################################
# 1. MISE A JOUR SYSTEME & INSTALLATION DES DEPENDANCES
##############################################################################
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/10] Mise à jour du système..."
apt-get update -y
apt-get upgrade -y

echo ">>> [1/10] Installation de Nginx, PHP 8.3, MySQL Server, Node.js, NPM, Mailutils, Curl, jq, stress-ng..."
apt-get install -y \
    nginx \
    mysql-server \
    php8.3-fpm \
    php8.3-mysql \
    php8.3-curl \
    php8.3-xml \
    php8.3-mbstring \
    php8.3-zip \
    php8.3-gd \
    php8.3-redis \
    redis-server \
    nodejs \
    npm \
    mailutils \
    curl \
    jq \
    unzip \
    bc \
    python3 \
    stress-ng

npm install -g pm2

##############################################################################
# 1B. DURCISSEMENT SYSTEME (gratuit) : SSH, mises à jour auto, fail2ban
#
# Ajouté lors du renforcement sécurité/réseau/admin sys du projet. Trois
# actions, toutes gratuites (paquets open-source déjà dans les dépôts
# Ubuntu, aucune ressource Azure supplémentaire) :
#   1. Durcissement de la configuration SSH (sshd_config).
#   2. unattended-upgrades : applique automatiquement les correctifs de
#      sécurité Ubuntu, sans intervention manuelle.
#   3. fail2ban : bannit temporairement (pare-feu local, iptables) toute IP
#      qui échoue trop de fois à se connecter en SSH ou au dashboard.
##############################################################################
echo ">>> [1B] Durcissement SSH, mises à jour automatiques, fail2ban..."

apt-get install -y fail2ban unattended-upgrades

# --- 1. Durcissement SSH -----------------------------------------------
# L'authentification par mot de passe est déjà désactivée côté Azure
# (disable_password_authentication = true dans modules/vm/main.tf), mais on
# le répète explicitement ici au niveau du démon SSH lui-même (défense en
# profondeur, utile aussi si la VM est un jour reconfigurée hors Terraform).
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-blockhash-hardening.conf << 'SSHD_EOF'
# Durcissement SSH BlockHash - voir README, section Sécurité.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD_EOF

systemctl reload sshd || systemctl reload ssh || true

# --- 2. Mises à jour de sécurité automatiques ---------------------------
# Applique quotidiennement (via systemd timer intégré au paquet) les seuls
# correctifs de SÉCURITÉ Ubuntu, sans redémarrage automatique de la VM
# (Unattended-Upgrade::Automatic-Reboot "false" - un redémarrage silencieux
# et non planifié sur une VM de prod serait pire que le risque évité).
cat > /etc/apt/apt.conf.d/51blockhash-unattended-upgrades << 'UU_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UU_EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AU_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AU_EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

# --- 3. fail2ban (SSH + dashboard) ---------------------------------------
# Jail SSH : configuration par défaut de fail2ban (jail sshd), suffisante
# ici puisque l'authentification par mot de passe est déjà désactivée -
# fail2ban protège malgré tout contre le bruit/la charge des scanners.
cat > /etc/fail2ban/jail.d/blockhash-sshd.conf << 'F2B_SSH_EOF'
[sshd]
enabled  = true
port     = 22
maxretry = 4
findtime = 600
bantime  = 3600
F2B_SSH_EOF

# Jail dashboard BlockHash : le backend Node.js (voir étape 6/9 plus bas)
# journalise chaque échec de connexion dans /var/log/blockhash-auth.log
# au format "BLOCKHASH_AUTH_FAIL <ip>", que fail2ban surveille ici. Vient
# en complément (niveau réseau/iptables) de l'anti brute-force déjà présent
# au niveau applicatif (5 tentatives/5 min/IP, express-session).
mkdir -p /var/log
touch /var/log/blockhash-auth.log
chmod 640 /var/log/blockhash-auth.log

cat > /etc/fail2ban/filter.d/blockhash-dashboard.conf << 'F2B_FILTER_EOF'
[Definition]
failregex = ^BLOCKHASH_AUTH_FAIL <HOST>$
ignoreregex =
F2B_FILTER_EOF

cat > /etc/fail2ban/jail.d/blockhash-dashboard.conf << 'F2B_DASH_EOF'
[blockhash-dashboard]
enabled  = true
filter   = blockhash-dashboard
logpath  = /var/log/blockhash-auth.log
maxretry = 5
findtime = 300
bantime  = 3600
action   = iptables-allports[name=blockhash-dashboard]
F2B_DASH_EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo ">>> [1B] Durcissement système terminé (SSH, unattended-upgrades, fail2ban)."

##############################################################################
# 2. ACCES AZURE KEY VAULT VIA L'IDENTITE MANAGEE DE LA VM
##############################################################################
echo ">>> [2/10] Mise en place de l'accès à Key Vault (identité managée)..."

mkdir -p /etc/blockhash

# Fichier de configuration NON SECRET : ne contient que des NOMS (Key Vault,
# secrets), jamais de valeur sensible. Lisible uniquement par root.
cat > /etc/blockhash/keyvault.env << ENV_EOF
KEY_VAULT_NAME=${key_vault_name}
MYSQL_LOGIN_SECRET_NAME=${mysql_admin_login_secret_name}
MYSQL_PASSWORD_SECRET_NAME=${mysql_admin_password_secret_name}
ALERT_WEBHOOK_SECRET_NAME=${alert_webhook_url_secret_name}
DASHBOARD_PASSWORD_SECRET_NAME=${dashboard_admin_password_secret_name}
ALERT_EMAIL=${alert_email}
ENV_EOF

chmod 600 /etc/blockhash/keyvault.env
chown root:root /etc/blockhash/keyvault.env

# ----------------------------------------------------------------------------
# kv-get-secret.sh : récupère la VALEUR d'un secret Key Vault à l'exécution,
# via l'identité managée système de la VM (aucun identifiant stocké sur
# disque). Utilisé aussi bien pendant le provisioning initial que plus tard
# par monitor.sh (récupération du webhook d'alerte à la demande).
#
# Usage : kv-get-secret.sh <nom-du-secret> [tentatives_max] [delai_secondes]
# ----------------------------------------------------------------------------
cat > /usr/local/bin/kv-get-secret.sh << 'KVGET_EOF'
#!/bin/bash
set -euo pipefail

SECRET_NAME="$1"
MAX_ATTEMPTS="$${2:-5}"
SLEEP_SECONDS="$${3:-10}"

source /etc/blockhash/keyvault.env

ATTEMPT=1
while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    # Etape 1 : obtention d'un jeton OAuth2 pour la ressource "vault.azure.net"
    # via le service de métadonnées de l'instance (IMDS), accessible
    # uniquement depuis l'intérieur de la VM.
    TOKEN=$(curl -s -H "Metadata: true" \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
        | jq -r '.access_token' 2>/dev/null || true)

    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        # Etape 2 : appel de l'API REST Key Vault pour lire la valeur du
        # secret demandé, authentifié par le jeton obtenu ci-dessus.
        VALUE=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "https://$KEY_VAULT_NAME.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" \
            | jq -r '.value' 2>/dev/null || true)

        if [ -n "$VALUE" ] && [ "$VALUE" != "null" ]; then
            echo "$VALUE"
            exit 0
        fi
    fi

    # La propagation des rôles RBAC Azure peut prendre jusqu'à quelques
    # dizaines de secondes après la création de la VM : on retente avec un
    # délai plutôt que d'échouer immédiatement.
    sleep "$SLEEP_SECONDS"
    ATTEMPT=$((ATTEMPT + 1))
done

echo "ERREUR: impossible de récupérer le secret '$SECRET_NAME' depuis Key Vault '$KEY_VAULT_NAME' après $MAX_ATTEMPTS tentatives." >&2
exit 1
KVGET_EOF

chmod 700 /usr/local/bin/kv-get-secret.sh

##############################################################################
# 3. INSTALLATION & CONFIGURATION DE MYSQL SERVER (LOCAL)
##############################################################################
echo ">>> [3/10] Installation et configuration de MySQL Server local..."

systemctl enable mysql
systemctl start mysql

# Attente que le service MySQL soit pleinement opérationnel (le socket peut
# mettre quelques secondes à apparaître juste après l'installation du paquet).
for i in $(seq 1 30); do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi
    sleep 2
done

echo ">>> [3/10] Récupération des identifiants MySQL depuis Azure Key Vault..."

# Récupérés UNE SEULE FOIS ici, puis réutilisés à l'étape 5 (wp-config.php)
# via ces mêmes variables d'environnement exportées - évite un second aller-
# retour vers Key Vault pour la même information.
source /etc/blockhash/keyvault.env

export MYSQL_ADMIN_LOGIN
export MYSQL_ADMIN_PASSWORD
MYSQL_ADMIN_LOGIN=$(/usr/local/bin/kv-get-secret.sh "$MYSQL_LOGIN_SECRET_NAME" 20 15)
MYSQL_ADMIN_PASSWORD=$(/usr/local/bin/kv-get-secret.sh "$MYSQL_PASSWORD_SECRET_NAME" 20 15)

echo ">>> [3/10] Création de la base '${mysql_database_name}' et de l'utilisateur applicatif local..."

# Le mot de passe n'est JAMAIS passé en argument de ligne de commande (ce
# qui serait visible via "ps aux") : il est transmis au client mysql via
# l'entrée standard (heredoc non quoté, avec expansion bash normale des
# variables d'environnement ci-dessus). Les identifiants ne sont écrits
# nulle part sur le disque de la VM. "IF NOT EXISTS" + "ALTER USER" rendent
# ce bloc rejouable sans erreur (idempotence en cas de ré-exécution).
mysql -u root <<SQL_EOF
CREATE DATABASE IF NOT EXISTS \`${mysql_database_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$MYSQL_ADMIN_LOGIN'@'localhost' IDENTIFIED BY '$MYSQL_ADMIN_PASSWORD';
ALTER USER '$MYSQL_ADMIN_LOGIN'@'localhost' IDENTIFIED BY '$MYSQL_ADMIN_PASSWORD';
GRANT ALL PRIVILEGES ON \`${mysql_database_name}\`.* TO '$MYSQL_ADMIN_LOGIN'@'localhost';
FLUSH PRIVILEGES;
SQL_EOF

# Durcissement minimal, équivalent partiel de "mysql_secure_installation" :
# suppression des comptes anonymes, interdiction du compte root en dehors
# de localhost, suppression de la base "test" par défaut. MySQL écoute par
# défaut uniquement sur 127.0.0.1 (bind-address de base Ubuntu), ce qui
# suffit ici puisque WordPress se connecte exclusivement en local.
mysql -u root <<SQL_EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL_EOF

echo ">>> [3/10] MySQL Server local opérationnel (base '${mysql_database_name}' prête)."

##############################################################################
# 4. CONFIGURATION NGINX
##############################################################################
echo ">>> [4/10] Configuration du format de log enrichi (latence applicative)..."

# Le paquet nginx d'Ubuntu inclut automatiquement tout fichier présent dans
# /etc/nginx/conf.d/ à l'intérieur du bloc "http" de nginx.conf (directive
# "include /etc/nginx/conf.d/*.conf;" déjà présente par défaut) : on peut
# donc déclarer un log_format personnalisé ici sans jamais avoir à modifier
# nginx.conf lui-même (plus sûr qu'une édition en place par sed/awk).
mkdir -p /etc/nginx/conf.d

cat > /etc/nginx/conf.d/blockhash-log-format.conf << 'LOGFORMAT_EOF'
# Format de log BlockHash : ajoute le temps de traitement de la requête
# ($request_time, PHP-FPM inclus), indispensable pour calculer la latence
# moyenne / p95 affichée dans le dashboard de monitoring.
log_format blockhash '$remote_addr - $remote_user [$time_local] '
                      '"$request" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent" '
                      'rt=$request_time';
LOGFORMAT_EOF

echo ">>> [4/10] Configuration du virtual host Nginx..."

cat > /etc/nginx/sites-available/blockhash << 'NGINX_EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html;

    client_max_body_size 64M;

    access_log /var/log/nginx/access.log blockhash;
    error_log  /var/log/nginx/error.log;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    # Le dashboard entier (page HTML, API REST, WebSocket) est désormais
    # intégralement proxifié vers le backend Node.js, qui applique lui-même
    # l'authentification par session AVANT de servir le moindre fichier.
    # (v2 servait /dashboard en fichiers statiques via "alias", ce qui
    # contournait totalement l'authentification applicative - corrigé ici.)
    location /dashboard {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cookie_path / /;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_cookie_path / /;
    }

    location ~* /(wp-config\.php|\.htaccess) {
        deny all;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/blockhash /etc/nginx/sites-enabled/blockhash
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl enable php8.3-fpm
systemctl restart php8.3-fpm
systemctl restart nginx

##############################################################################
# 5. DEPLOIEMENT & CONFIGURATION DE WORDPRESS (connexion MySQL locale)
##############################################################################
echo ">>> [5/10] Téléchargement et déploiement de WordPress..."

cd /tmp
curl -sSL -O https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

rm -rf /var/www/html/*
cp -r /tmp/wordpress/* /var/www/html/
rm -rf /tmp/wordpress /tmp/latest.tar.gz

cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

echo ">>> [5/10] Injection des identifiants MySQL dans wp-config.php..."

# MYSQL_ADMIN_LOGIN et MYSQL_ADMIN_PASSWORD ont déjà été récupérés depuis
# Key Vault à l'étape 3 (et restent exportés dans l'environnement de ce
# script) : inutile de les redemander à Key Vault une seconde fois.

# Injection via Python3 (remplacement littéral, sans interprétation de
# caractères spéciaux) plutôt que sed/perl : garantit que le mot de passe
# généré aléatoirement (qui peut contenir des caractères spéciaux de
# regex/sed) est inséré tel quel, sans risque de corruption du fichier.
python3 - << 'PYEOF'
import os

path = "/var/www/html/wp-config.php"
with open(path, "r") as f:
    content = f.read()

content = content.replace("username_here", os.environ["MYSQL_ADMIN_LOGIN"])
content = content.replace("password_here", os.environ["MYSQL_ADMIN_PASSWORD"])

with open(path, "w") as f:
    f.write(content)
PYEOF

# Le nom de la base n'est PAS un secret (un nom de base seul ne permet
# aucune connexion sans les identifiants ci-dessus) : il est injecté
# directement par Terraform. DB_HOST reste "localhost" - valeur par défaut
# de wp-config-sample.php - puisque MySQL tourne désormais SUR CETTE VM
# (aucun remplacement de host nécessaire, contrairement à la v1 qui
# pointait vers le FQDN d'un serveur MySQL Flexible Server distant).
sed -i "s/database_name_here/${mysql_database_name}/" /var/www/html/wp-config.php

# NOTE (v2) : la directive MYSQLI_CLIENT_SSL a été retirée. Elle était
# nécessaire pour Azure MySQL Flexible Server (connexion chiffrée
# obligatoire) ; une connexion locale à 127.0.0.1 n'a pas de certificat TLS
# configuré côté serveur MySQL local, donc forcer SSL ici empêcherait
# WordPress de se connecter.

# Génération de clés de sécurité (salts) aléatoires officielles WordPress.
curl -sSL https://api.wordpress.org/secret-key/1.1/salt/ > /tmp/wp-salts.txt
sed -i "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" /var/www/html/wp-config.php
sed -i "/DB_COLLATE/r /tmp/wp-salts.txt" /var/www/html/wp-config.php
rm -f /tmp/wp-salts.txt

# Nettoyage immédiat des variables d'environnement contenant les
# identifiants, une fois l'injection terminée (bonne pratique défensive).
unset MYSQL_ADMIN_LOGIN
unset MYSQL_ADMIN_PASSWORD

# ----------------------------------------------------------------------------
# ETAPE 9 (performance, gratuit) : cache objet Redis local.
# Réduit la charge MySQL/PHP en mettant en cache les requêtes répétées de
# WordPress (options, requêtes de menu, etc.). redis-server + php8.3-redis
# sont installés à l'étape 1 ; Redis écoute par défaut uniquement sur
# 127.0.0.1 sous Ubuntu (aucune exposition réseau), on le confirme
# explicitement ci-dessous par défense en profondeur.
sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server

# Drop-in officiel WordPress/Redis (object-cache.php) : active le cache
# objet sans dépendre d'un plugin tiers à mettre à jour séparément.
curl -sSL -o /var/www/html/wp-content/object-cache.php \
    https://raw.githubusercontent.com/rhubarbgroup/redis-cache/develop/includes/object-cache.php || \
    echo ">>> [5/10] AVERTISSEMENT : téléchargement du drop-in Redis échoué, cache objet désactivé (non bloquant)."

python3 - << 'PYEOF'
path = "/var/www/html/wp-config.php"
with open(path, "r") as f:
    content = f.read()

# ETAPE 9 : active le cache objet Redis (utilisé par le drop-in ci-dessus).
# ETAPE 10 (gratuit) : mises à jour automatiques WordPress - le coeur ET
# les extensions/thèmes se mettent à jour seuls (correctifs de sécurité
# WordPress publiés régulièrement), sans intervention manuelle sur la VM.
auto_update_defines = (
    "define( 'WP_REDIS_HOST', '127.0.0.1' );\n"
    "define( 'WP_REDIS_PORT', 6379 );\n"
    "define( 'WP_CACHE', true );\n"
    "define( 'WP_AUTO_UPDATE_CORE', true );\n"
    "define( 'AUTOMATIC_UPDATER_DISABLED', false );\n"
)
marker = "/* That's all, stop editing"
content = content.replace(marker, auto_update_defines + marker)

with open(path, "w") as f:
    f.write(content)
PYEOF

mkdir -p /var/www/html/dashboard
chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

# Active l'auto-update des plugins/thèmes existants (le coeur est déjà géré
# par les defines ci-dessus) via WP-CLI - plus fiable que de patcher les
# fichiers core à la main, et idempotent en cas de ré-exécution.
if ! command -v wp >/dev/null 2>&1; then
    curl -sSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
        chmod +x /usr/local/bin/wp || \
        echo ">>> [5/10] AVERTISSEMENT : installation de WP-CLI échouée (non bloquant, auto-update plugins/thèmes ignoré)."
fi

if command -v wp >/dev/null 2>&1; then
    sudo -u www-data wp plugin auto-updates enable --all --path=/var/www/html || true
    sudo -u www-data wp theme auto-updates enable --all --path=/var/www/html || true
fi


##############################################################################
# 6. CONFIGURATION DE L'AUTHENTIFICATION DU DASHBOARD (Key Vault)
##############################################################################
echo ">>> [6/10] Récupération des identifiants du dashboard depuis Key Vault..."

source /etc/blockhash/keyvault.env

# Le mot de passe est stocké dans un fichier NON world-readable
# (chmod 600, propriétaire root), lu au démarrage par le process Node.js du
# dashboard (lancé par pm2 en tant que root, comme le reste de la stack de
# ce projet). Il n'est jamais interpolé par Terraform ni écrit en dur : sa
# valeur provient uniquement de Key Vault, récupérée à l'exécution via
# l'identité managée de la VM (même mécanisme que pour MySQL).
DASHBOARD_ADMIN_PASSWORD=$(/usr/local/bin/kv-get-secret.sh "$DASHBOARD_PASSWORD_SECRET_NAME" 20 15)

cat > /etc/blockhash/dashboard-auth.env << AUTH_EOF
DASHBOARD_ADMIN_USER=${dashboard_admin_username}
DASHBOARD_ADMIN_PASSWORD=$DASHBOARD_ADMIN_PASSWORD
AUTH_EOF

chmod 600 /etc/blockhash/dashboard-auth.env
chown root:root /etc/blockhash/dashboard-auth.env

unset DASHBOARD_ADMIN_PASSWORD

echo ">>> [6/10] Authentification du dashboard configurée (utilisateur : ${dashboard_admin_username})."

##############################################################################
# 7. SCRIPT DE MONITORING ENRICHI (monitor.sh) + SCRIPT DE TEST (test_5xx.sh)
##############################################################################
echo ">>> [7/10] Installation du script de monitoring /usr/local/bin/monitor.sh..."

cat > /usr/local/bin/monitor.sh << 'MONITOR_EOF'
#!/bin/bash
##############################################################################
# monitor.sh - Script de surveillance applicative & système pour BlockHash.
#
# Exécuté toutes les 5 minutes par cron (voir /etc/cron.d/blockhash-monitor).
# Le webhook d'alerte n'est JAMAIS stocké en clair sur disque : il est
# récupéré depuis Key Vault via kv-get-secret.sh, uniquement au moment où
# une alerte doit effectivement être envoyée (voir send_alert ci-dessous).
# Chaque alerte est également journalisée dans /var/log/blockhash-incidents.log,
# lu en direct par le dashboard Node.js pour son journal d'incidents.
##############################################################################

WEBSITE_URL="http://localhost/"
NGINX_LOG="/var/log/nginx/access.log"

THRESHOLD_5XX_RATE=5
THRESHOLD_CPU=85
THRESHOLD_RAM=90
THRESHOLD_DISK=85

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
ALERTS=""

send_alert() {
    local message="$1"
    echo "[ALERTE] $message"

    # Journalisation persistante de l'incident : le backend Node.js du
    # dashboard suit ce fichier en continu (tail -F, même mécanisme que pour
    # les logs Nginx) afin d'alimenter le journal d'incidents affiché dans
    # l'interface et de déclencher une notification "toast" en direct.
    echo "$TIMESTAMP|$message" >> /var/log/blockhash-incidents.log

    source /etc/blockhash/keyvault.env

    if [ -n "$ALERT_WEBHOOK_SECRET_NAME" ]; then
        # Récupération du webhook à la demande uniquement : peu d'appels
        # Key Vault au global (seulement en cas d'alerte réelle), et la
        # valeur n'est jamais persistée sur le disque de la VM.
        WEBHOOK_URL=$(/usr/local/bin/kv-get-secret.sh "$ALERT_WEBHOOK_SECRET_NAME" 3 5 2>/dev/null || true)

        if [ -n "$WEBHOOK_URL" ]; then
            curl -s -H "Content-Type: application/json" \
                 -X POST \
                 -d "{\"content\": \"BlockHash Monitor ALERTE : $message\"}" \
                 "$WEBHOOK_URL" > /dev/null || true
        fi
    fi

    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "[BlockHash] Alerte monitoring - $TIMESTAMP" "$ALERT_EMAIL" || true
    fi
}

# ----------------------------------------------------------------------------
# 1. Vérification de la disponibilité HTTP du site.
# ----------------------------------------------------------------------------
HTTP_STATUS=$(curl -o /dev/null -s -m 10 -w "%%{http_code}" "$WEBSITE_URL")

if [ "$HTTP_STATUS" = "000" ]; then
    ALERTS="$ALERTS Site injoignable (HTTP 000, Nginx probablement down)."
fi

# ----------------------------------------------------------------------------
# 2. Taux d'erreurs HTTP 5xx sur les 1000 dernières requêtes Nginx.
# ----------------------------------------------------------------------------
if [ -f "$NGINX_LOG" ]; then
    ERROR_RATE=$(tail -n 1000 "$NGINX_LOG" | awk '
        {
            total++
            if (substr($9, 1, 1) == "5") { errors++ }
        }
        END {
            if (total > 0) { printf "%.2f", (errors / total) * 100 }
            else { print "0" }
        }
    ')
else
    ERROR_RATE="0"
fi

if [ "$(echo "$ERROR_RATE > $THRESHOLD_5XX_RATE" | bc -l)" = "1" ]; then
    ALERTS="$ALERTS Taux d'erreurs 5xx élevé : $ERROR_RATE% (seuil $THRESHOLD_5XX_RATE%)."
fi

# ----------------------------------------------------------------------------
# 3. Charge CPU.
# ----------------------------------------------------------------------------
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk -F',' '{print $4}' | awk '{print $1}')
CPU_USAGE=$(echo "100 - $CPU_IDLE" | bc -l)
CPU_USAGE=$(printf "%.2f" "$CPU_USAGE")

if [ "$(echo "$CPU_USAGE > $THRESHOLD_CPU" | bc -l)" = "1" ]; then
    ALERTS="$ALERTS Charge CPU élevée : $CPU_USAGE% (seuil $THRESHOLD_CPU%)."
fi

# ----------------------------------------------------------------------------
# 4. Utilisation mémoire RAM.
# ----------------------------------------------------------------------------
RAM_USAGE=$(free | awk '/Mem:/ {printf "%.2f", ($3/$2) * 100}')

if [ "$(echo "$RAM_USAGE > $THRESHOLD_RAM" | bc -l)" = "1" ]; then
    ALERTS="$ALERTS Utilisation RAM élevée : $RAM_USAGE% (seuil $THRESHOLD_RAM%)."
fi

# ----------------------------------------------------------------------------
# 5. Espace disque utilisé sur la partition racine.
# ----------------------------------------------------------------------------
DISK_USAGE=$(df -h / | awk 'NR==2 {gsub("%","",$5); print $5}')

if [ "$DISK_USAGE" -gt "$THRESHOLD_DISK" ]; then
    ALERTS="$ALERTS Espace disque élevé : $DISK_USAGE% (seuil $THRESHOLD_DISK%)."
fi

# ----------------------------------------------------------------------------
# 6. Disponibilité du service MySQL local (v2 : MySQL tourne sur cette VM).
#    Une base injoignable en local casse WordPress exactement comme un
#    Nginx down : c'est donc une sonde critique au même titre que le HTTP.
# ----------------------------------------------------------------------------
if ! mysqladmin ping --silent 2>/dev/null; then
    ALERTS="$ALERTS Service MySQL local injoignable (mysqladmin ping a échoué)."
fi

echo "$TIMESTAMP | HTTP=$HTTP_STATUS | 5xx=$ERROR_RATE% | CPU=$CPU_USAGE% | RAM=$RAM_USAGE% | DISK=$DISK_USAGE%"

if [ -n "$ALERTS" ]; then
    send_alert "$ALERTS"
fi

exit 0
MONITOR_EOF

chmod +x /usr/local/bin/monitor.sh

echo ">>> [7/10] Installation du script de test d'alerte /usr/local/bin/test_5xx.sh..."

cat > /usr/local/bin/test_5xx.sh << 'TEST_EOF'
#!/bin/bash
##############################################################################
# test_5xx.sh - Déclenche artificiellement des erreurs HTTP 500 afin de
# valider la chaîne d'alerte de monitor.sh (y compris la récupération du
# webhook depuis Key Vault).
##############################################################################

TEST_FILE="/var/www/html/blockhash-test-500.php"

echo "Création du fichier de test HTTP 500..."
cat > "$TEST_FILE" << 'PHP_EOF'
<?php
http_response_code(500);
echo "Simulated 500 error for BlockHash monitoring test.";
PHP_EOF

chown www-data:www-data "$TEST_FILE"

echo "Envoi de 30 requêtes de test vers $TEST_FILE ..."
for i in $(seq 1 30); do
    curl -s -o /dev/null "http://localhost/blockhash-test-500.php"
done

echo "Exécution de monitor.sh pour vérifier la détection..."
/usr/local/bin/monitor.sh

echo "Nettoyage du fichier de test..."
rm -f "$TEST_FILE"

echo "Test terminé."
TEST_EOF

chmod +x /usr/local/bin/test_5xx.sh

echo ">>> [7/10] Installation du script de test de charge CPU /usr/local/bin/test_cpu_stress.sh..."

cat > /usr/local/bin/test_cpu_stress.sh << 'TEST_CPU_EOF'
#!/bin/bash
##############################################################################
# test_cpu_stress.sh - Genere une charge CPU artificielle sur tous les
# coeurs de la VM via stress-ng, afin de valider la sonde de charge CPU de
# monitor.sh (seuil : 85 %) et l'affichage temps reel du dashboard.
#
# Usage : test_cpu_stress.sh [duree_en_secondes]  (defaut : 60)
##############################################################################

DURATION="$${1:-60}"

echo "Demarrage d'une charge CPU sur $(nproc) coeur(s) pendant $${DURATION}s..."
stress-ng --cpu "$(nproc)" --timeout "$${DURATION}s"

echo "Charge CPU terminee."
TEST_CPU_EOF

chmod +x /usr/local/bin/test_cpu_stress.sh

echo ">>> [7/10] Installation du script de test de latence /usr/local/bin/test_high_latency.sh..."

cat > /usr/local/bin/test_high_latency.sh << 'TEST_LATENCY_EOF'
#!/bin/bash
##############################################################################
# test_high_latency.sh - Simule une degradation du temps de reponse
# applicatif (page PHP volontairement lente) afin de valider le calcul de
# latence moyenne / p95 affiche dans les KPIs du dashboard.
#
# Usage : test_high_latency.sh [nombre_requetes] [duree_sleep_secondes]
#         (defauts : 15 requetes, 3 secondes de pause par requete)
##############################################################################

TEST_FILE="/var/www/html/blockhash-test-latency.php"
REQUEST_COUNT="$${1:-15}"
SLEEP_SECONDS="$${2:-3}"

echo "Creation de la page de test (pause de $${SLEEP_SECONDS}s par requete)..."
cat > "$TEST_FILE" << 'PHP_EOF'
<?php
sleep(SLEEP_PLACEHOLDER);
echo "Simulated slow response for BlockHash latency test.";
PHP_EOF

sed -i "s/SLEEP_PLACEHOLDER/$SLEEP_SECONDS/" "$TEST_FILE"
chown www-data:www-data "$TEST_FILE"

echo "Envoi de $REQUEST_COUNT requetes lentes vers $TEST_FILE ..."
for i in $(seq 1 "$REQUEST_COUNT"); do
    curl -s -o /dev/null "http://localhost/blockhash-test-latency.php"
done

echo "Nettoyage de la page de test..."
rm -f "$TEST_FILE"

echo "Test de latence termine."
TEST_LATENCY_EOF

chmod +x /usr/local/bin/test_high_latency.sh

echo ">>> [7/10] Installation du script de test de coupure MySQL /usr/local/bin/test_mysql_down.sh..."

cat > /usr/local/bin/test_mysql_down.sh << 'TEST_MYSQL_EOF'
#!/bin/bash
##############################################################################
# test_mysql_down.sh - Interrompt temporairement le service MySQL local afin
# de valider la sonde de disponibilite MySQL de monitor.sh et la chaine
# d'alerte associee. Le service est redemarre automatiquement a la fin du
# test. ATTENTION : WordPress est indisponible pendant la duree du test.
#
# Usage : test_mysql_down.sh [duree_en_secondes]  (defaut : 20)
##############################################################################

DURATION="$${1:-20}"

echo "Arret temporaire de MySQL pendant $${DURATION}s..."
systemctl stop mysql

sleep "$DURATION"

echo "Redemarrage de MySQL..."
systemctl start mysql

for i in $(seq 1 15); do
    if mysqladmin ping --silent 2>/dev/null; then
        echo "MySQL de nouveau disponible."
        break
    fi
    sleep 2
done

echo "Test de coupure MySQL termine."
TEST_MYSQL_EOF

chmod +x /usr/local/bin/test_mysql_down.sh

##############################################################################
# 8. PLANIFICATION CRON DU MONITORING (toutes les 5 minutes)
##############################################################################
echo ">>> [8/10] Planification cron de monitor.sh..."

cat > /etc/cron.d/blockhash-monitor << 'CRON_EOF'
*/5 * * * * root /usr/local/bin/monitor.sh >> /var/log/blockhash-monitor.log 2>&1
CRON_EOF

chmod 644 /etc/cron.d/blockhash-monitor
touch /var/log/blockhash-monitor.log
touch /var/log/blockhash-incidents.log
chmod 644 /var/log/blockhash-incidents.log

##############################################################################
# 9. BACKEND NODE.JS - API, AUTHENTIFICATION, WEBSOCKETS (dashboard/server.js)
##############################################################################
echo ">>> [9/10] Déploiement du backend Node.js (dashboard/server.js)..."

mkdir -p /var/www/html/dashboard
mkdir -p /var/lib/blockhash

cat > /var/www/html/dashboard/package.json << 'PKG_EOF'
{
  "name": "blockhash-dashboard-server",
  "version": "2.0.0",
  "description": "Backend du dashboard entreprise BlockHash : auth, API, WebSocket temps reel",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "express-session": "^1.18.0",
    "socket.io": "^4.7.5"
  }
}
PKG_EOF

cat > /var/www/html/dashboard/server.js << 'SERVER_EOF'
// ============================================================================
// server.js - Backend du Dashboard entreprise BlockHash
//
// Fonctionnalités :
//   - Authentification par session (identifiants lus depuis un fichier local
//     non world-readable, alimenté par Key Vault au provisioning).
//   - Diffusion temps réel des métriques système (CPU/RAM/Disque/HTTP) via
//     Socket.io, réservée aux sockets authentifiés.
//   - Persistance de l'historique des métriques sur disque (JSON Lines),
//     avec API de lecture par plage temporelle (1h/6h/24h/7j).
//   - Calcul de KPIs : disponibilité (uptime) 24h/7j, latence moyenne/p95
//     (à partir de $request_time Nginx), volume de requêtes du jour.
//   - Analyse en direct du flux de logs Nginx : répartition des codes HTTP,
//     top endpoints, top adresses IP.
//   - Panneau de santé des services système (Nginx, PHP-FPM, MySQL,
//     dashboard lui-même).
//   - Journal d'incidents persistant (alimenté par monitor.sh), avec
//     notification "toast" en direct.
//
// NOTE : ce fichier n'utilise volontairement AUCUN template literal
// JavaScript (chaines entre backticks avec interpolation) afin d'eviter tout conflit
// avec le mecanisme d'interpolation "templatefile" de Terraform qui a
// genere le script cloud-init injectant ce fichier. Toutes les
// concatenations de chaines utilisent l'operateur "+".
// ============================================================================

var express = require("express");
var session = require("express-session");
var http = require("http");
var os = require("os");
var fs = require("fs");
var path = require("path");
var crypto = require("crypto");
var child_process = require("child_process");
var socketio = require("socket.io");

var app = express();
var server = http.createServer(app);
var io = socketio(server, {
    cors: { origin: "*" }
});

var PORT = 3000;
var NGINX_ACCESS_LOG = "/var/log/nginx/access.log";
var INCIDENTS_LOG = "/var/log/blockhash-incidents.log";
var DATA_DIR = "/var/lib/blockhash";
var METRICS_HISTORY_FILE = path.join(DATA_DIR, "metrics-history.jsonl");
var INCIDENTS_HISTORY_FILE = path.join(DATA_DIR, "incidents.jsonl");
var MAX_HISTORY_LINES = 10080; // ~7 jours a 1 point / minute

try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
} catch (e) {
    console.log("Impossible de creer " + DATA_DIR + " : " + e.message);
}

// ----------------------------------------------------------------------------
// Authentification : identifiants lus depuis un fichier local (non commite,
// non world-readable) alimente par Key Vault au provisioning de la VM.
// Aucun mot de passe n'est jamais code en dur dans ce fichier.
// ----------------------------------------------------------------------------
var AUTH_FILE = "/etc/blockhash/dashboard-auth.env";
var authConfig = { user: "admin", password: null };

function loadAuthConfig() {
    try {
        var raw = fs.readFileSync(AUTH_FILE, "utf8");
        raw.split("\n").forEach(function (line) {
            var trimmed = line.trim();
            if (!trimmed || trimmed.indexOf("=") === -1) {
                return;
            }
            var idx = trimmed.indexOf("=");
            var key = trimmed.substring(0, idx).trim();
            var value = trimmed.substring(idx + 1).trim();
            if (key === "DASHBOARD_ADMIN_USER") {
                authConfig.user = value;
            } else if (key === "DASHBOARD_ADMIN_PASSWORD") {
                authConfig.password = value;
            }
        });
    } catch (e) {
        console.log("ATTENTION : impossible de lire " + AUTH_FILE + " (" + e.message + "). Authentification indisponible.");
    }
}
loadAuthConfig();

// Comparaison en temps constant pour eviter les attaques par mesure de
// temps de reponse sur la comparaison du mot de passe.
function safeCompare(a, b) {
    var bufA = Buffer.from(String(a));
    var bufB = Buffer.from(String(b));
    if (bufA.length !== bufB.length) {
        // Compare quand meme un buffer factice de meme longueur pour ne
        // pas laisser fuiter d'information via le temps d'execution.
        crypto.timingSafeEqual(bufA, bufA);
        return false;
    }
    return crypto.timingSafeEqual(bufA, bufB);
}

// Limitation basique des tentatives de connexion (anti brute-force) : 5
// echecs maximum par IP, blocage de 5 minutes. En complement (defense en
// profondeur, niveau reseau), chaque echec est aussi journalise dans
// /var/log/blockhash-auth.log au format que surveille fail2ban (jail
// "blockhash-dashboard", voir user_data.sh etape 1B) : au-dela de 5 echecs
// en 5 minutes, l'IP est carrement bannie par iptables, pas seulement
// bloquee au niveau applicatif.
var loginAttempts = {};
var MAX_LOGIN_ATTEMPTS = 5;
var LOGIN_LOCKOUT_MS = 5 * 60 * 1000;
var AUTH_LOG_PATH = "/var/log/blockhash-auth.log";

function isLockedOut(ip) {
    var entry = loginAttempts[ip];
    if (!entry) {
        return false;
    }
    if (entry.count >= MAX_LOGIN_ATTEMPTS && (Date.now() - entry.lastAttempt) < LOGIN_LOCKOUT_MS) {
        return true;
    }
    if ((Date.now() - entry.lastAttempt) >= LOGIN_LOCKOUT_MS) {
        delete loginAttempts[ip];
    }
    return false;
}

function registerFailedAttempt(ip) {
    if (!loginAttempts[ip]) {
        loginAttempts[ip] = { count: 0, lastAttempt: 0 };
    }
    loginAttempts[ip].count += 1;
    loginAttempts[ip].lastAttempt = Date.now();

    // Journalisation pour fail2ban - ne doit jamais faire planter le login
    // (best-effort : une erreur d'ecriture disque ne doit pas bloquer
    // l'utilisateur legitime a cote).
    fs.appendFile(AUTH_LOG_PATH, "BLOCKHASH_AUTH_FAIL " + ip + "\n", function (err) {
        if (err) {
            console.error("Impossible d'ecrire dans " + AUTH_LOG_PATH + " :", err.message);
        }
    });
}

function clearAttempts(ip) {
    delete loginAttempts[ip];
}

// Secret de session genere aleatoirement au demarrage du process : les
// sessions ne survivent pas a un redemarrage de pm2, ce qui est un
// compromis acceptable pour un outil interne (evite de gerer un secret de
// session supplementaire a stocker).
var sessionMiddleware = session({
    secret: crypto.randomBytes(32).toString("hex"),
    name: "blockhash.sid",
    resave: false,
    saveUninitialized: false,
    cookie: {
        httpOnly: true,
        sameSite: "lax",
        maxAge: 8 * 60 * 60 * 1000 // 8 heures
    }
});

app.use(express.json());
app.use(sessionMiddleware);

function authRequired(req, res, next) {
    if (req.session && req.session.authenticated) {
        next();
        return;
    }
    if (req.path.indexOf("/api/") !== -1) {
        res.status(401).json({ error: "unauthorized" });
        return;
    }
    res.redirect("/dashboard/login");
}

// ----------------------------------------------------------------------------
// Routes publiques (login) - enregistrees AVANT le middleware d'auth pour
// rester accessibles sans session valide.
// ----------------------------------------------------------------------------
app.get("/dashboard/login", function (req, res) {
    res.sendFile(path.join(__dirname, "login.html"));
});

app.post("/dashboard/api/login", function (req, res) {
    var ip = req.ip || "unknown";

    if (isLockedOut(ip)) {
        res.status(429).json({ error: "too_many_attempts" });
        return;
    }

    var body = req.body || {};
    var username = String(body.username || "");
    var password = String(body.password || "");

    if (authConfig.password === null) {
        res.status(500).json({ error: "auth_not_configured" });
        return;
    }

    var userOk = safeCompare(username, authConfig.user);
    var passOk = safeCompare(password, authConfig.password);

    if (userOk && passOk) {
        clearAttempts(ip);
        req.session.authenticated = true;
        req.session.username = username;
        res.json({ success: true });
    } else {
        registerFailedAttempt(ip);
        res.status(401).json({ error: "invalid_credentials" });
    }
});

app.post("/dashboard/api/logout", function (req, res) {
    req.session.destroy(function () {
        res.json({ success: true });
    });
});

// ----------------------------------------------------------------------------
// A partir d'ici, TOUTE requete /dashboard/* exige une session valide.
// ----------------------------------------------------------------------------
app.use(authRequired);

app.get(["/dashboard", "/dashboard/"], function (req, res) {
    res.sendFile(path.join(__dirname, "index.html"));
});

// ----------------------------------------------------------------------------
// Collecte des metriques systeme (reprise de la logique existante).
// ----------------------------------------------------------------------------
function getCpuUsagePercent(callback) {
    var start = os.cpus();

    setTimeout(function () {
        var end = os.cpus();
        var idleDiff = 0;
        var totalDiff = 0;

        for (var i = 0; i < start.length; i++) {
            var startCpu = start[i].times;
            var endCpu = end[i].times;

            var startIdle = startCpu.idle;
            var endIdle = endCpu.idle;

            var startTotal = startCpu.user + startCpu.nice + startCpu.sys + startCpu.idle + startCpu.irq;
            var endTotal = endCpu.user + endCpu.nice + endCpu.sys + endCpu.idle + endCpu.irq;

            idleDiff += (endIdle - startIdle);
            totalDiff += (endTotal - startTotal);
        }

        var usage = 100 - (100 * idleDiff / totalDiff);
        callback(Math.round(usage * 100) / 100);
    }, 200);
}

function getRamUsagePercent() {
    var total = os.totalmem();
    var free = os.freemem();
    var used = total - free;
    return Math.round((used / total) * 10000) / 100;
}

function getDiskUsagePercent(callback) {
    child_process.exec("df -h / | awk 'NR==2 {gsub(\"%\",\"\",$5); print $5}'", function (err, stdout) {
        if (err) {
            callback(0);
            return;
        }
        callback(parseFloat(stdout.trim()) || 0);
    });
}

function getWebStatus(callback) {
    child_process.exec("curl -o /dev/null -s -m 5 -w '%%{http_code}' http://localhost/", function (err, stdout) {
        if (err) {
            callback("000");
            return;
        }
        callback(stdout.trim());
    });
}

// ----------------------------------------------------------------------------
// Analyse en direct des logs Nginx : codes HTTP, top endpoints, top IPs,
// latence applicative ($request_time, capture "rt=X.XXX" en fin de ligne).
// Compteurs en memoire, reinitialises a chaque redemarrage du process
// (compromis acceptable pour un outil interne sans base de donnees dediee).
// ----------------------------------------------------------------------------
var statusCodeCounts = { "2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0, other: 0 };
var endpointCounts = {};
var ipCounts = {};
var latencySamples = [];
var requestsToday = 0;
var requestsTodayDate = new Date().toISOString().slice(0, 10);
var MAX_LATENCY_SAMPLES = 1000;

// Regex du format de log "blockhash" defini dans nginx.conf :
// IP - user [date] "METHODE /chemin PROTO" STATUT TAILLE "referer" "agent" rt=TEMPS
var LOG_LINE_REGEX = /^(\S+) \S+ \S+ \[[^\]]+\] "(\S+) (\S+) [^"]*" (\d{3}) \d+ "[^"]*" "[^"]*" rt=([0-9.]+|-)/;

function recordLogLine(line) {
    var match = LOG_LINE_REGEX.exec(line);
    if (!match) {
        return;
    }

    var ip = match[1];
    var requestPath = match[3];
    var status = match[4];
    var rt = match[5];

    var today = new Date().toISOString().slice(0, 10);
    if (today !== requestsTodayDate) {
        requestsTodayDate = today;
        requestsToday = 0;
        endpointCounts = {};
        ipCounts = {};
        statusCodeCounts = { "2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0, other: 0 };
    }
    requestsToday += 1;

    var statusClass = status.charAt(0) + "xx";
    if (statusCodeCounts.hasOwnProperty(statusClass)) {
        statusCodeCounts[statusClass] += 1;
    } else {
        statusCodeCounts.other += 1;
    }

    endpointCounts[requestPath] = (endpointCounts[requestPath] || 0) + 1;
    ipCounts[ip] = (ipCounts[ip] || 0) + 1;

    if (rt !== "-") {
        var rtMs = parseFloat(rt) * 1000;
        if (!isNaN(rtMs)) {
            latencySamples.push(rtMs);
            if (latencySamples.length > MAX_LATENCY_SAMPLES) {
                latencySamples.shift();
            }
        }
    }
}

function topEntries(counterObject, limit) {
    var entries = Object.keys(counterObject).map(function (key) {
        return { key: key, count: counterObject[key] };
    });
    entries.sort(function (a, b) { return b.count - a.count; });
    return entries.slice(0, limit);
}

function percentile(sortedArray, p) {
    if (sortedArray.length === 0) {
        return 0;
    }
    var idx = Math.min(sortedArray.length - 1, Math.floor((p / 100) * sortedArray.length));
    return sortedArray[idx];
}

// ----------------------------------------------------------------------------
// Flux de logs Nginx : diffusion aux clients (terminal live) + analyse.
// ----------------------------------------------------------------------------
function startLogStream() {
    if (!fs.existsSync(NGINX_ACCESS_LOG)) {
        console.log("Log Nginx introuvable, nouvelle tentative dans 5s...");
        setTimeout(startLogStream, 5000);
        return;
    }

    var tail = child_process.spawn("tail", ["-F", "-n", "0", NGINX_ACCESS_LOG]);

    tail.stdout.on("data", function (data) {
        var lines = data.toString().split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.length > 0) {
                recordLogLine(line);
                io.emit("logline", line);
            }
        }
    });

    tail.on("error", function (err) {
        console.log("Erreur tail -F (access.log) : " + err.message);
    });
}

// ----------------------------------------------------------------------------
// Flux d'incidents : suit /var/log/blockhash-incidents.log alimente par
// monitor.sh, persiste chaque nouvel incident et notifie les clients
// connectes en direct (notification "toast").
// ----------------------------------------------------------------------------
function persistIncident(timestamp, message) {
    try {
        var entry = JSON.stringify({ t: timestamp, message: message }) + "\n";
        fs.appendFileSync(INCIDENTS_HISTORY_FILE, entry);
    } catch (e) {
        console.log("Impossible de persister l'incident : " + e.message);
    }
}

function startIncidentStream() {
    // Le fichier peut ne pas encore exister au tout premier demarrage : on
    // s'assure de sa presence avant de le suivre.
    try {
        fs.closeSync(fs.openSync(INCIDENTS_LOG, "a"));
    } catch (e) {
        console.log("Impossible de creer " + INCIDENTS_LOG + " : " + e.message);
    }

    var tail = child_process.spawn("tail", ["-F", "-n", "0", INCIDENTS_LOG]);

    tail.stdout.on("data", function (data) {
        var lines = data.toString().split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line.length === 0) {
                continue;
            }
            var sepIdx = line.indexOf("|");
            var timestamp = sepIdx !== -1 ? line.substring(0, sepIdx) : new Date().toISOString();
            var message = sepIdx !== -1 ? line.substring(sepIdx + 1) : line;

            persistIncident(timestamp, message);
            io.emit("incident", { t: timestamp, message: message });
        }
    });

    tail.on("error", function (err) {
        console.log("Erreur tail -F (incidents.log) : " + err.message);
    });
}

// ----------------------------------------------------------------------------
// Boucle de diffusion des metriques systeme (3s) + persistance historique
// (1 point par minute dans metrics-history.jsonl).
// ----------------------------------------------------------------------------
var lastMetricsSnapshot = null;
var ticksSinceLastPersist = 0;
var PERSIST_EVERY_N_TICKS = 20; // 20 x 3s = 60s

function appendMetricsHistory(snapshot) {
    try {
        var entry = JSON.stringify(snapshot) + "\n";
        fs.appendFileSync(METRICS_HISTORY_FILE, entry);
    } catch (e) {
        console.log("Impossible de persister les metriques : " + e.message);
        return;
    }

    ticksSinceLastPersist = 0;

    // Purge legere : toutes les ~100 ecritures, on verifie la taille du
    // fichier et on le tronque si necessaire pour eviter une croissance
    // illimitee (retention ciblee : ~7 jours a 1 point/minute).
    if (Math.random() < 0.01) {
        try {
            var lines = fs.readFileSync(METRICS_HISTORY_FILE, "utf8").split("\n").filter(Boolean);
            if (lines.length > MAX_HISTORY_LINES) {
                var trimmed = lines.slice(lines.length - MAX_HISTORY_LINES).join("\n") + "\n";
                fs.writeFileSync(METRICS_HISTORY_FILE, trimmed);
            }
        } catch (e) {
            console.log("Purge de l'historique impossible : " + e.message);
        }
    }
}

setInterval(function () {
    getCpuUsagePercent(function (cpu) {
        getDiskUsagePercent(function (disk) {
            getWebStatus(function (webStatus) {
                var payload = {
                    timestamp: new Date().toISOString(),
                    cpu: cpu,
                    ram: getRamUsagePercent(),
                    disk: disk,
                    webStatus: webStatus,
                    hostname: os.hostname()
                };

                lastMetricsSnapshot = payload;
                io.emit("metrics", payload);

                ticksSinceLastPersist += 1;
                if (ticksSinceLastPersist >= PERSIST_EVERY_N_TICKS) {
                    appendMetricsHistory({
                        t: payload.timestamp,
                        cpu: payload.cpu,
                        ram: payload.ram,
                        disk: payload.disk,
                        webStatus: payload.webStatus
                    });
                }
            });
        });
    });
}, 3000);

// ----------------------------------------------------------------------------
// API REST - toutes protegees par authRequired (deja applique plus haut).
// ----------------------------------------------------------------------------

// Historique des metriques pour le graphique multi-plages.
app.get("/dashboard/api/metrics-history", function (req, res) {
    var range = req.query.range || "1h";
    var rangeMs = { "1h": 3600000, "6h": 21600000, "24h": 86400000, "7d": 604800000 }[range] || 3600000;
    var since = Date.now() - rangeMs;

    var points = [];
    try {
        var lines = fs.readFileSync(METRICS_HISTORY_FILE, "utf8").split("\n").filter(Boolean);
        for (var i = 0; i < lines.length; i++) {
            try {
                var obj = JSON.parse(lines[i]);
                if (new Date(obj.t).getTime() >= since) {
                    points.push(obj);
                }
            } catch (e) {
                // Ligne corrompue : ignoree silencieusement.
            }
        }
    } catch (e) {
        // Pas encore d'historique disponible (VM tout juste demarree).
    }

    // Sous-echantillonnage si trop de points pour un rendu de graphique
    // fluide (au-dela de ~300 points, on garde 1 point sur N).
    var maxPoints = 300;
    if (points.length > maxPoints) {
        var step = Math.ceil(points.length / maxPoints);
        points = points.filter(function (_, idx) { return idx % step === 0; });
    }

    res.json({ range: range, points: points });
});

// KPIs consolides : uptime 24h/7j, latence, requetes du jour, incidents actifs.
app.get("/dashboard/api/kpis", function (req, res) {
    var now = Date.now();
    var uptime = { "24h": null, "7d": null };

    try {
        var lines = fs.readFileSync(METRICS_HISTORY_FILE, "utf8").split("\n").filter(Boolean);
        ["24h", "7d"].forEach(function (rangeKey) {
            var rangeMs = rangeKey === "24h" ? 86400000 : 604800000;
            var since = now - rangeMs;
            var total = 0;
            var up = 0;
            for (var i = 0; i < lines.length; i++) {
                try {
                    var obj = JSON.parse(lines[i]);
                    if (new Date(obj.t).getTime() >= since) {
                        total += 1;
                        if (obj.webStatus !== "000") {
                            up += 1;
                        }
                    }
                } catch (e) {
                    // ignore
                }
            }
            uptime[rangeKey] = total > 0 ? Math.round((up / total) * 10000) / 100 : null;
        });
    } catch (e) {
        // Pas encore d'historique.
    }

    var sortedLatencies = latencySamples.slice().sort(function (a, b) { return a - b; });
    var avgLatency = sortedLatencies.length > 0
        ? Math.round(sortedLatencies.reduce(function (a, b) { return a + b; }, 0) / sortedLatencies.length)
        : null;
    var p95Latency = sortedLatencies.length > 0 ? Math.round(percentile(sortedLatencies, 95)) : null;

    var incidentsToday = 0;
    try {
        var incidentLines = fs.readFileSync(INCIDENTS_HISTORY_FILE, "utf8").split("\n").filter(Boolean);
        var since24h = now - 86400000;
        incidentLines.forEach(function (line) {
            try {
                var obj = JSON.parse(line);
                if (new Date(obj.t).getTime() >= since24h) {
                    incidentsToday += 1;
                }
            } catch (e) {
                // ignore
            }
        });
    } catch (e) {
        // Pas encore d'incidents.
    }

    res.json({
        uptime24h: uptime["24h"],
        uptime7d: uptime["7d"],
        avgLatencyMs: avgLatency,
        p95LatencyMs: p95Latency,
        requestsToday: requestsToday,
        incidentsLast24h: incidentsToday
    });
});

app.get("/dashboard/api/status-codes", function (req, res) {
    res.json(statusCodeCounts);
});

app.get("/dashboard/api/top-endpoints", function (req, res) {
    res.json(topEntries(endpointCounts, 10));
});

app.get("/dashboard/api/top-ips", function (req, res) {
    res.json(topEntries(ipCounts, 10));
});

app.get("/dashboard/api/incidents", function (req, res) {
    var incidents = [];
    try {
        var lines = fs.readFileSync(INCIDENTS_HISTORY_FILE, "utf8").split("\n").filter(Boolean);
        incidents = lines.slice(-50).map(function (line) {
            try {
                return JSON.parse(line);
            } catch (e) {
                return null;
            }
        }).filter(Boolean).reverse();
    } catch (e) {
        // Pas encore d'incidents enregistres.
    }
    res.json(incidents);
});

app.get("/dashboard/api/services", function (req, res) {
    var services = ["nginx", "php8.3-fpm", "mysql"];
    var results = { dashboard: "active" };
    var pending = services.length;

    services.forEach(function (svc) {
        child_process.exec("systemctl is-active " + svc, function (err, stdout) {
            results[svc] = stdout.trim() === "active" ? "active" : "inactive";
            pending -= 1;
            if (pending === 0) {
                res.json(results);
            }
        });
    });
});

// ----------------------------------------------------------------------------
// Socket.io : partage du middleware de session Express afin de n'accepter
// que les connexions WebSocket provenant d'un navigateur authentifie.
// ----------------------------------------------------------------------------
io.engine.use(sessionMiddleware);

io.use(function (socket, next) {
    var sess = socket.request.session;
    if (sess && sess.authenticated) {
        next();
        return;
    }
    next(new Error("unauthorized"));
});

// ----------------------------------------------------------------------------
// Registre des scripts de test declenchables depuis le dashboard. Chaque
// entree associe un identifiant (utilise cote client) au script shell
// correspondant sur la VM, avec ses arguments par defaut. Voir
// modules/vm/scripts/user_data.sh pour le contenu de chaque script.
// ----------------------------------------------------------------------------
var TEST_SCRIPTS = {
    http_5xx: { path: "/usr/local/bin/test_5xx.sh", args: [] },
    cpu_stress: { path: "/usr/local/bin/test_cpu_stress.sh", args: ["60"] },
    high_latency: { path: "/usr/local/bin/test_high_latency.sh", args: ["15", "3"] },
    mysql_down: { path: "/usr/local/bin/test_mysql_down.sh", args: ["20"] }
};

io.on("connection", function (socket) {
    console.log("Client dashboard connecte : " + socket.id);

    if (lastMetricsSnapshot) {
        socket.emit("metrics", lastMetricsSnapshot);
    }

    socket.on("disconnect", function () {
        console.log("Client dashboard deconnecte : " + socket.id);
    });

    socket.on("trigger_test", function (payload) {
        var testId = payload && payload.test;
        var test = TEST_SCRIPTS[testId];

        if (!test) {
            socket.emit("test_result", { test: testId, success: false, output: "Test inconnu." });
            return;
        }

        var command = test.path + " " + test.args.join(" ");
        child_process.exec(command, { timeout: 180000 }, function (err, stdout) {
            io.emit("test_result", { test: testId, success: !err, output: stdout || "" });
        });
    });
});

startLogStream();
startIncidentStream();

// ETAPE 1 (sécurité réseau) : liaison EXPLICITE à 127.0.0.1 uniquement.
// Sans cette précision, Node.js écoute par défaut sur 0.0.0.0 (toutes les
// interfaces), ce qui rendait le dashboard joignable EN DIRECT sur le port
// 3000 depuis Internet, en contournant totalement Nginx. La règle NSG qui
// ouvrait ce port a été retirée (modules/network/main.tf) ; ce changement
// applicatif est la seconde moitié de la correction (défense en profondeur :
// même si une règle réseau était ré-ouverte par erreur, le process
// n'écouterait toujours que localement).
server.listen(PORT, "127.0.0.1", function () {
    console.log("Serveur dashboard BlockHash demarre sur 127.0.0.1:" + PORT);
});
SERVER_EOF

cd /var/www/html/dashboard
npm install --production

# Redemarre proprement si une precedente instance pm2 existe deja
# (rejouabilite du script en cas de re-provisioning manuel).
pm2 delete blockhash-dashboard > /dev/null 2>&1 || true
pm2 start server.js --name blockhash-dashboard
pm2 startup systemd -u root --hp /root > /tmp/pm2-startup.log 2>&1 || true
bash /tmp/pm2-startup.log > /dev/null 2>&1 || true
pm2 save

##############################################################################
# 10. FRONTEND DASHBOARD ENTREPRISE (login.html + index.html)
##############################################################################
echo ">>> [10/10] Déploiement du frontend dashboard (login.html + index.html)..."

cat > /var/www/html/dashboard/login.html << 'LOGIN_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BlockHash - Connexion</title>
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://unpkg.com/lucide@latest/dist/umd/lucide.min.js"></script>
<style>
    body {
        background: radial-gradient(circle at top left, #0f172a 0%, #020617 60%, #000000 100%);
        min-height: 100vh;
        font-family: 'Segoe UI', system-ui, sans-serif;
        color: #e2e8f0;
    }
    .glass-card {
        background: rgba(255, 255, 255, 0.05);
        backdrop-filter: blur(18px);
        -webkit-backdrop-filter: blur(18px);
        border: 1px solid rgba(255, 255, 255, 0.10);
        border-radius: 1rem;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.45);
    }
</style>
</head>
<body class="flex items-center justify-center min-h-screen p-6">

    <div class="glass-card w-full max-w-sm p-8">
        <div class="flex flex-col items-center mb-6">
            <div class="w-12 h-12 rounded-xl bg-indigo-500/20 border border-indigo-400/30 flex items-center justify-center mb-3">
                <i data-lucide="shield-check" class="w-6 h-6 text-indigo-400"></i>
            </div>
            <h1 class="text-xl font-bold text-white">BlockHash Ops</h1>
            <p class="text-slate-400 text-sm mt-1">Connexion au dashboard de supervision</p>
        </div>

        <form id="login-form" class="flex flex-col gap-4">
            <div>
                <label class="text-xs text-slate-400 mb-1 block">Utilisateur</label>
                <input type="text" id="username" autocomplete="username" required
                    class="w-full bg-slate-800/60 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:outline-none focus:border-indigo-400" />
            </div>
            <div>
                <label class="text-xs text-slate-400 mb-1 block">Mot de passe</label>
                <input type="password" id="password" autocomplete="current-password" required
                    class="w-full bg-slate-800/60 border border-slate-700 rounded-lg px-3 py-2 text-sm text-white focus:outline-none focus:border-indigo-400" />
            </div>

            <p id="login-error" class="text-xs text-rose-400 hidden"></p>

            <button type="submit"
                class="w-full bg-indigo-500/90 hover:bg-indigo-500 transition rounded-lg py-2.5 text-sm font-semibold text-white flex items-center justify-center gap-2">
                <i data-lucide="log-in" class="w-4 h-4"></i>
                Se connecter
            </button>
        </form>
    </div>

<script>
    lucide.createIcons();

    var form = document.getElementById("login-form");
    var errorEl = document.getElementById("login-error");

    form.addEventListener("submit", function (event) {
        event.preventDefault();
        errorEl.classList.add("hidden");

        var username = document.getElementById("username").value;
        var password = document.getElementById("password").value;

        fetch("/dashboard/api/login", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ username: username, password: password })
        })
            .then(function (response) {
                if (response.ok) {
                    window.location.href = "/dashboard/";
                    return;
                }
                return response.json().then(function (data) {
                    var messages = {
                        invalid_credentials: "Identifiants incorrects.",
                        too_many_attempts: "Trop de tentatives - reessayez dans quelques minutes.",
                        auth_not_configured: "Authentification non configuree cote serveur."
                    };
                    errorEl.textContent = messages[data.error] || "Erreur de connexion.";
                    errorEl.classList.remove("hidden");
                });
            })
            .catch(function () {
                errorEl.textContent = "Erreur reseau - reessayez.";
                errorEl.classList.remove("hidden");
            });
    });
</script>
</body>
</html>
LOGIN_EOF

cat > /var/www/html/dashboard/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BlockHash - Dashboard de Monitoring</title>

<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
<script src="https://unpkg.com/lucide@latest/dist/umd/lucide.min.js"></script>

<style>
    :root {
        --bg-grad-1: #0f172a;
        --bg-grad-2: #020617;
        --bg-grad-3: #000000;
        --text-main: #e2e8f0;
        --text-muted: #94a3b8;
        --card-bg: rgba(255, 255, 255, 0.05);
        --card-border: rgba(255, 255, 255, 0.10);
        --table-border: rgba(255, 255, 255, 0.08);
    }
    html[data-theme="light"] {
        --bg-grad-1: #f1f5f9;
        --bg-grad-2: #e2e8f0;
        --bg-grad-3: #ffffff;
        --text-main: #0f172a;
        --text-muted: #475569;
        --card-bg: rgba(255, 255, 255, 0.65);
        --card-border: rgba(15, 23, 42, 0.10);
        --table-border: rgba(15, 23, 42, 0.08);
    }
    body {
        background: radial-gradient(circle at top left, var(--bg-grad-1) 0%, var(--bg-grad-2) 60%, var(--bg-grad-3) 100%);
        min-height: 100vh;
        font-family: 'Segoe UI', system-ui, sans-serif;
        color: var(--text-main);
        transition: background 0.2s ease, color 0.2s ease;
    }
    .glass-card {
        background: var(--card-bg);
        backdrop-filter: blur(18px);
        -webkit-backdrop-filter: blur(18px);
        border: 1px solid var(--card-border);
        border-radius: 1rem;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.25);
    }
    .text-muted { color: var(--text-muted); }
    .status-dot {
        width: 10px;
        height: 10px;
        border-radius: 9999px;
        display: inline-block;
        box-shadow: 0 0 8px currentColor;
    }
    #log-terminal {
        background: rgba(0, 0, 0, 0.45);
        font-family: 'Courier New', monospace;
        font-size: 0.78rem;
        line-height: 1.35rem;
        overflow-y: auto;
    }
    #log-terminal::-webkit-scrollbar { width: 8px; }
    #log-terminal::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15); border-radius: 4px; }
    table.data-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
    table.data-table th { text-align: left; color: var(--text-muted); font-weight: 500; padding: 6px 8px; border-bottom: 1px solid var(--table-border); }
    table.data-table td { padding: 6px 8px; border-bottom: 1px solid var(--table-border); }
    .range-btn { padding: 4px 10px; border-radius: 9999px; font-size: 0.75rem; border: 1px solid var(--card-border); color: var(--text-muted); }
    .range-btn.active { background: rgba(99,102,241,0.25); color: #a5b4fc; border-color: rgba(129,140,248,0.5); }
    .toast { animation: toast-in 0.25s ease; }
    @keyframes toast-in { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: translateY(0); } }
</style>
</head>
<body class="p-6 md:p-10">

    <header class="flex flex-col md:flex-row md:items-center md:justify-between mb-8 gap-4">
        <div>
            <h1 class="text-3xl font-bold tracking-tight">BlockHash <span class="text-indigo-400">Ops</span></h1>
            <p class="text-muted text-sm mt-1">Dashboard de monitoring - Infrastructure Azure</p>
        </div>
        <div class="flex items-center gap-3">
            <span id="connection-indicator" class="status-dot bg-slate-500 text-slate-500"></span>
            <span id="connection-label" class="text-sm text-muted">Connexion...</span>
            <button id="btn-theme-toggle" class="glass-card px-3 py-1.5 rounded-lg text-sm flex items-center gap-1.5">
                <i data-lucide="moon" class="w-4 h-4"></i>
            </button>
            <button id="btn-logout" class="glass-card px-3 py-1.5 rounded-lg text-sm flex items-center gap-1.5 text-rose-400">
                <i data-lucide="log-out" class="w-4 h-4"></i>
                Deconnexion
            </button>
        </div>
    </header>

    <!-- ==================== TOASTS ==================== -->
    <div id="toast-container" class="fixed top-4 right-4 z-50 flex flex-col gap-2 w-80"></div>

    <!-- ==================== KPIs ==================== -->
    <section class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
        <div class="glass-card p-4">
            <p class="text-muted text-xs">Disponibilite 24h</p>
            <p id="kpi-uptime-24h" class="text-xl font-bold mt-1">--</p>
        </div>
        <div class="glass-card p-4">
            <p class="text-muted text-xs">Disponibilite 7j</p>
            <p id="kpi-uptime-7d" class="text-xl font-bold mt-1">--</p>
        </div>
        <div class="glass-card p-4">
            <p class="text-muted text-xs">Latence moy. / p95</p>
            <p id="kpi-latency" class="text-xl font-bold mt-1">--</p>
        </div>
        <div class="glass-card p-4">
            <p class="text-muted text-xs">Requetes aujourd'hui</p>
            <p id="kpi-requests" class="text-xl font-bold mt-1">--</p>
        </div>
        <div class="glass-card p-4">
            <p class="text-muted text-xs">Incidents (24h)</p>
            <p id="kpi-incidents" class="text-xl font-bold mt-1">--</p>
        </div>
    </section>

    <!-- ==================== CARTES TEMPS REEL ==================== -->
    <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5 mb-6">
        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-muted text-sm">Statut Web</span>
                <i data-lucide="globe" class="w-5 h-5 text-indigo-400"></i>
            </div>
            <p id="web-status-value" class="text-2xl font-bold mt-3">--</p>
            <p id="web-status-sub" class="text-xs text-muted mt-1">En attente de donnees</p>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-muted text-sm">CPU</span>
                <i data-lucide="cpu" class="w-5 h-5 text-emerald-400"></i>
            </div>
            <p id="cpu-value" class="text-2xl font-bold mt-3">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="cpu-bar" class="bg-emerald-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-muted text-sm">RAM</span>
                <i data-lucide="memory-stick" class="w-5 h-5 text-amber-400"></i>
            </div>
            <p id="ram-value" class="text-2xl font-bold mt-3">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="ram-bar" class="bg-amber-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-muted text-sm">Disque</span>
                <i data-lucide="hard-drive" class="w-5 h-5 text-rose-400"></i>
            </div>
            <p id="disk-value" class="text-2xl font-bold mt-3">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="disk-bar" class="bg-rose-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>
    </section>

    <!-- ==================== HISTORIQUE (plage temporelle) ==================== -->
    <section class="glass-card p-5 mb-6">
        <div class="flex items-center justify-between mb-3 flex-wrap gap-2">
            <h2 class="font-semibold">Historique CPU / RAM / Disque</h2>
            <div class="flex gap-2">
                <button class="range-btn" data-range="1h">1h</button>
                <button class="range-btn" data-range="6h">6h</button>
                <button class="range-btn active" data-range="24h">24h</button>
                <button class="range-btn" data-range="7d">7j</button>
            </div>
        </div>
        <canvas id="history-chart" height="80"></canvas>
    </section>

    <!-- ==================== CODES HTTP + SANTE DES SERVICES ==================== -->
    <section class="grid grid-cols-1 lg:grid-cols-3 gap-5 mb-6">
        <div class="glass-card p-5">
            <h2 class="font-semibold mb-3">Repartition des codes HTTP</h2>
            <canvas id="status-chart" height="180"></canvas>
        </div>

        <div class="glass-card p-5 lg:col-span-2">
            <h2 class="font-semibold mb-3">Sante des services</h2>
            <div id="services-panel" class="grid grid-cols-2 md:grid-cols-4 gap-3"></div>
        </div>
    </section>

    <!-- ==================== SCRIPTS DE TEST ==================== -->
    <section class="glass-card p-5 mb-6">
        <h2 class="font-semibold mb-1">Scripts de test</h2>
        <p class="text-muted text-xs mb-4">Declenchent une situation degradee controlee (et auto-reversible) afin de valider la chaine de supervision complete : sonde monitor.sh, alerte, journal d'incidents.</p>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
            <div class="glass-card p-4 flex flex-col gap-2">
                <div class="flex items-center gap-2">
                    <i data-lucide="server-crash" class="w-4 h-4 text-rose-400"></i>
                    <span class="text-sm font-medium">Erreurs HTTP 500</span>
                </div>
                <p class="text-xs text-muted flex-1">Envoie 30 requetes en erreur 500. Valide la sonde de taux d'erreurs 5xx (seuil 5%).</p>
                <button class="test-btn bg-rose-500/20 hover:bg-rose-500/30 border border-rose-400/30 text-rose-300 rounded-lg py-2 text-xs font-medium" data-test="http_5xx">
                    Lancer le test
                </button>
            </div>

            <div class="glass-card p-4 flex flex-col gap-2">
                <div class="flex items-center gap-2">
                    <i data-lucide="cpu" class="w-4 h-4 text-amber-400"></i>
                    <span class="text-sm font-medium">Charge CPU</span>
                </div>
                <p class="text-xs text-muted flex-1">Sature tous les coeurs pendant 60s. Valide la sonde de charge CPU (seuil 85%) et le graphique temps reel.</p>
                <button class="test-btn bg-amber-500/20 hover:bg-amber-500/30 border border-amber-400/30 text-amber-300 rounded-lg py-2 text-xs font-medium" data-test="cpu_stress">
                    Lancer le test
                </button>
            </div>

            <div class="glass-card p-4 flex flex-col gap-2">
                <div class="flex items-center gap-2">
                    <i data-lucide="timer" class="w-4 h-4 text-amber-400"></i>
                    <span class="text-sm font-medium">Latence elevee</span>
                </div>
                <p class="text-xs text-muted flex-1">15 requetes volontairement lentes (3s). Valide le KPI de latence moyenne / p95.</p>
                <button class="test-btn bg-amber-500/20 hover:bg-amber-500/30 border border-amber-400/30 text-amber-300 rounded-lg py-2 text-xs font-medium" data-test="high_latency">
                    Lancer le test
                </button>
            </div>

            <div class="glass-card p-4 flex flex-col gap-2">
                <div class="flex items-center gap-2">
                    <i data-lucide="database-zap" class="w-4 h-4 text-rose-400"></i>
                    <span class="text-sm font-medium">Coupure MySQL</span>
                </div>
                <p class="text-xs text-muted flex-1">Arrete MySQL local 20s puis le redemarre. Valide la sonde de disponibilite MySQL. WordPress indisponible pendant le test.</p>
                <button class="test-btn bg-rose-500/20 hover:bg-rose-500/30 border border-rose-400/30 text-rose-300 rounded-lg py-2 text-xs font-medium" data-test="mysql_down">
                    Lancer le test
                </button>
            </div>
        </div>

        <p id="test-result" class="text-xs text-muted mt-3"></p>
    </section>

    <!-- ==================== TOP ENDPOINTS / TOP IPs ==================== -->
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-5 mb-6">
        <div class="glass-card p-5">
            <h2 class="font-semibold mb-3">Top endpoints</h2>
            <table class="data-table">
                <thead><tr><th>Chemin</th><th>Requetes</th></tr></thead>
                <tbody id="top-endpoints-body"></tbody>
            </table>
        </div>
        <div class="glass-card p-5">
            <h2 class="font-semibold mb-3">Top adresses IP</h2>
            <table class="data-table">
                <thead><tr><th>IP</th><th>Requetes</th></tr></thead>
                <tbody id="top-ips-body"></tbody>
            </table>
        </div>
    </section>

    <!-- ==================== INCIDENTS + LOGS ==================== -->
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-5 mb-6">
        <div class="glass-card p-5">
            <h2 class="font-semibold mb-3 flex items-center gap-2">
                <i data-lucide="siren" class="w-4 h-4"></i>
                Journal d'incidents
            </h2>
            <div id="incidents-list" class="flex flex-col gap-2 max-h-64 overflow-y-auto text-sm"></div>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between mb-3">
                <h2 class="font-semibold flex items-center gap-2">
                    <i data-lucide="terminal" class="w-4 h-4"></i>
                    Logs Nginx en direct
                </h2>
                <button id="btn-clear-logs" class="text-xs text-muted hover:underline">Effacer</button>
            </div>
            <div id="log-terminal" class="rounded-lg p-4 h-64"></div>
        </div>
    </section>

    <footer class="text-center text-xs text-muted pt-4 pb-8">
        Hote : <span id="hostname-value">--</span> · Derniere mise a jour : <span id="last-update-value">--</span>
    </footer>

<script>
    lucide.createIcons();

    // ------------------------------------------------------------------
    // Theme clair/sombre - persiste la preference dans localStorage
    // (page servee par notre propre backend, pas une preview d'artefact).
    // ------------------------------------------------------------------
    var themeBtn = document.getElementById("btn-theme-toggle");
    function applyTheme(theme) {
        document.documentElement.setAttribute("data-theme", theme);
        themeBtn.innerHTML = theme === "light"
            ? '<i data-lucide="sun" class="w-4 h-4"></i>'
            : '<i data-lucide="moon" class="w-4 h-4"></i>';
        lucide.createIcons();
    }
    var savedTheme = "dark";
    try { savedTheme = window.localStorage.getItem("blockhash-theme") || "dark"; } catch (e) {}
    applyTheme(savedTheme);

    themeBtn.addEventListener("click", function () {
        var current = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
        applyTheme(current);
        try { window.localStorage.setItem("blockhash-theme", current); } catch (e) {}
    });

    // ------------------------------------------------------------------
    // Deconnexion
    // ------------------------------------------------------------------
    document.getElementById("btn-logout").addEventListener("click", function () {
        fetch("/dashboard/api/logout", { method: "POST" }).then(function () {
            window.location.href = "/dashboard/login";
        });
    });

    // ------------------------------------------------------------------
    // Toasts de notification (incidents en direct)
    // ------------------------------------------------------------------
    function showToast(message) {
        var container = document.getElementById("toast-container");
        var toast = document.createElement("div");
        toast.className = "toast glass-card px-4 py-3 text-sm border-l-4 border-rose-400";
        toast.textContent = message;
        container.appendChild(toast);
        setTimeout(function () {
            toast.style.opacity = "0";
            toast.style.transition = "opacity 0.4s ease";
            setTimeout(function () { toast.remove(); }, 400);
        }, 8000);
    }

    // ------------------------------------------------------------------
    // Connexion Socket.io
    // ------------------------------------------------------------------
    var socket = io();
    var connectionIndicator = document.getElementById("connection-indicator");
    var connectionLabel = document.getElementById("connection-label");

    socket.on("connect", function () {
        connectionIndicator.className = "status-dot bg-emerald-400 text-emerald-400";
        connectionLabel.textContent = "Connecte";
    });

    socket.on("disconnect", function () {
        connectionIndicator.className = "status-dot bg-rose-500 text-rose-500";
        connectionLabel.textContent = "Deconnecte";
    });

    socket.on("connect_error", function () {
        // Session expiree ou invalide : renvoi vers la page de connexion.
        window.location.href = "/dashboard/login";
    });

    socket.on("metrics", function (data) {
        document.getElementById("cpu-value").textContent = data.cpu + "%";
        document.getElementById("cpu-bar").style.width = data.cpu + "%";
        document.getElementById("ram-value").textContent = data.ram + "%";
        document.getElementById("ram-bar").style.width = data.ram + "%";
        document.getElementById("disk-value").textContent = data.disk + "%";
        document.getElementById("disk-bar").style.width = data.disk + "%";

        var webStatusEl = document.getElementById("web-status-value");
        var webStatusSub = document.getElementById("web-status-sub");
        webStatusEl.textContent = data.webStatus;

        if (data.webStatus === "200") {
            webStatusEl.className = "text-2xl font-bold mt-3 text-emerald-400";
            webStatusSub.textContent = "Site operationnel";
        } else if (data.webStatus === "000") {
            webStatusEl.className = "text-2xl font-bold mt-3 text-rose-500";
            webStatusSub.textContent = "Site injoignable";
        } else {
            webStatusEl.className = "text-2xl font-bold mt-3 text-amber-400";
            webStatusSub.textContent = "Code retourne : " + data.webStatus;
        }

        document.getElementById("hostname-value").textContent = data.hostname;
        document.getElementById("last-update-value").textContent = new Date(data.timestamp).toLocaleTimeString();
    });

    socket.on("incident", function (incident) {
        showToast(incident.message);
        prependIncident(incident);
        refreshKpis();
    });

    // ------------------------------------------------------------------
    // Terminal de logs en direct
    // ------------------------------------------------------------------
    var logTerminal = document.getElementById("log-terminal");
    var maxLogLines = 300;

    socket.on("logline", function (line) {
        var lineEl = document.createElement("div");
        if (/\s5\d{2}\s/.test(line)) {
            lineEl.className = "text-rose-400";
        } else if (/\s4\d{2}\s/.test(line)) {
            lineEl.className = "text-amber-400";
        } else {
            lineEl.className = "text-muted";
        }
        lineEl.textContent = line;
        logTerminal.appendChild(lineEl);
        while (logTerminal.children.length > maxLogLines) {
            logTerminal.removeChild(logTerminal.firstChild);
        }
        logTerminal.scrollTop = logTerminal.scrollHeight;
    });

    document.getElementById("btn-clear-logs").addEventListener("click", function () {
        logTerminal.innerHTML = "";
    });

    document.querySelectorAll(".test-btn").forEach(function (btn) {
        btn.addEventListener("click", function () {
            var testId = btn.getAttribute("data-test");
            document.getElementById("test-result").textContent = "Test en cours (" + testId + ")...";
            socket.emit("trigger_test", { test: testId });
        });
    });

    socket.on("test_result", function (result) {
        var el = document.getElementById("test-result");
        el.textContent = result.success
            ? "Test '" + result.test + "' termine avec succes - verifiez le journal d'incidents et les KPIs ci-dessus."
            : "Le test '" + result.test + "' a rencontre une erreur.";
    });

    // ------------------------------------------------------------------
    // Graphique historique (plage selectionnable)
    // ------------------------------------------------------------------
    var historyCtx = document.getElementById("history-chart").getContext("2d");
    var historyChart = new Chart(historyCtx, {
        type: "line",
        data: {
            labels: [],
            datasets: [
                { label: "CPU %", data: [], borderColor: "#34d399", backgroundColor: "transparent", tension: 0.3, pointRadius: 0 },
                { label: "RAM %", data: [], borderColor: "#fbbf24", backgroundColor: "transparent", tension: 0.3, pointRadius: 0 },
                { label: "Disque %", data: [], borderColor: "#fb7185", backgroundColor: "transparent", tension: 0.3, pointRadius: 0 }
            ]
        },
        options: {
            responsive: true,
            animation: false,
            scales: {
                y: { min: 0, max: 100, ticks: { color: "#94a3b8" }, grid: { color: "rgba(148,163,184,0.1)" } },
                x: { ticks: { color: "#64748b", maxTicksLimit: 8 }, grid: { display: false } }
            },
            plugins: { legend: { labels: { color: "#94a3b8" } } }
        }
    });

    function loadHistory(range) {
        fetch("/dashboard/api/metrics-history?range=" + range)
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var labels = data.points.map(function (p) {
                    var d = new Date(p.t);
                    return range === "7d" ? (d.toLocaleDateString() + " " + d.toLocaleTimeString().slice(0, 5)) : d.toLocaleTimeString();
                });
                historyChart.data.labels = labels;
                historyChart.data.datasets[0].data = data.points.map(function (p) { return p.cpu; });
                historyChart.data.datasets[1].data = data.points.map(function (p) { return p.ram; });
                historyChart.data.datasets[2].data = data.points.map(function (p) { return p.disk; });
                historyChart.update();
            })
            .catch(function () {});
    }

    var rangeButtons = document.querySelectorAll(".range-btn");
    rangeButtons.forEach(function (btn) {
        btn.addEventListener("click", function () {
            rangeButtons.forEach(function (b) { b.classList.remove("active"); });
            btn.classList.add("active");
            loadHistory(btn.getAttribute("data-range"));
        });
    });
    loadHistory("24h");

    // ------------------------------------------------------------------
    // Donut des codes HTTP
    // ------------------------------------------------------------------
    var statusCtx = document.getElementById("status-chart").getContext("2d");
    var statusChart = new Chart(statusCtx, {
        type: "doughnut",
        data: {
            labels: ["2xx", "3xx", "4xx", "5xx", "Autre"],
            datasets: [{
                data: [0, 0, 0, 0, 0],
                backgroundColor: ["#34d399", "#60a5fa", "#fbbf24", "#fb7185", "#94a3b8"]
            }]
        },
        options: {
            responsive: true,
            plugins: { legend: { position: "bottom", labels: { color: "#94a3b8" } } }
        }
    });

    function loadStatusCodes() {
        fetch("/dashboard/api/status-codes")
            .then(function (r) { return r.json(); })
            .then(function (data) {
                statusChart.data.datasets[0].data = [data["2xx"], data["3xx"], data["4xx"], data["5xx"], data.other];
                statusChart.update();
            })
            .catch(function () {});
    }

    // ------------------------------------------------------------------
    // Top endpoints / Top IPs
    // ------------------------------------------------------------------
    function fillTable(bodyId, rows) {
        var body = document.getElementById(bodyId);
        body.innerHTML = "";
        if (rows.length === 0) {
            body.innerHTML = '<tr><td colspan="2" class="text-muted">Aucune donnee pour le moment</td></tr>';
            return;
        }
        rows.forEach(function (row) {
            var tr = document.createElement("tr");
            var tdKey = document.createElement("td");
            tdKey.textContent = row.key;
            var tdCount = document.createElement("td");
            tdCount.textContent = row.count;
            tr.appendChild(tdKey);
            tr.appendChild(tdCount);
            body.appendChild(tr);
        });
    }

    function loadTopLists() {
        fetch("/dashboard/api/top-endpoints").then(function (r) { return r.json(); }).then(function (rows) {
            fillTable("top-endpoints-body", rows);
        }).catch(function () {});

        fetch("/dashboard/api/top-ips").then(function (r) { return r.json(); }).then(function (rows) {
            fillTable("top-ips-body", rows);
        }).catch(function () {});
    }

    // ------------------------------------------------------------------
    // Sante des services
    // ------------------------------------------------------------------
    var serviceLabels = { nginx: "Nginx", "php8.3-fpm": "PHP-FPM", mysql: "MySQL", dashboard: "Dashboard" };

    function loadServices() {
        fetch("/dashboard/api/services")
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var panel = document.getElementById("services-panel");
                panel.innerHTML = "";
                Object.keys(serviceLabels).forEach(function (key) {
                    var status = data[key] || "inconnu";
                    var ok = status === "active";
                    var card = document.createElement("div");
                    card.className = "glass-card p-3 flex items-center gap-2";
                    var dot = document.createElement("span");
                    dot.className = "status-dot " + (ok ? "bg-emerald-400 text-emerald-400" : "bg-rose-500 text-rose-500");
                    var label = document.createElement("span");
                    label.className = "text-sm";
                    label.textContent = serviceLabels[key];
                    card.appendChild(dot);
                    card.appendChild(label);
                    panel.appendChild(card);
                });
            })
            .catch(function () {});
    }

    // ------------------------------------------------------------------
    // Journal d'incidents
    // ------------------------------------------------------------------
    function prependIncident(incident) {
        var list = document.getElementById("incidents-list");
        var empty = list.querySelector(".text-muted.italic");
        if (empty) { empty.remove(); }

        var row = document.createElement("div");
        row.className = "glass-card px-3 py-2 border-l-2 border-rose-400";
        var time = document.createElement("div");
        time.className = "text-xs text-muted";
        time.textContent = new Date(incident.t).toLocaleString();
        var msg = document.createElement("div");
        msg.textContent = incident.message;
        row.appendChild(time);
        row.appendChild(msg);
        list.insertBefore(row, list.firstChild);
    }

    function loadIncidents() {
        fetch("/dashboard/api/incidents")
            .then(function (r) { return r.json(); })
            .then(function (incidents) {
                var list = document.getElementById("incidents-list");
                list.innerHTML = "";
                if (incidents.length === 0) {
                    list.innerHTML = '<p class="text-muted italic">Aucun incident enregistre pour le moment.</p>';
                    return;
                }
                incidents.forEach(prependIncident);
            })
            .catch(function () {});
    }

    // ------------------------------------------------------------------
    // KPIs
    // ------------------------------------------------------------------
    function formatUptime(value) {
        return value === null || value === undefined ? "--" : value + "%";
    }

    function refreshKpis() {
        fetch("/dashboard/api/kpis")
            .then(function (r) { return r.json(); })
            .then(function (data) {
                document.getElementById("kpi-uptime-24h").textContent = formatUptime(data.uptime24h);
                document.getElementById("kpi-uptime-7d").textContent = formatUptime(data.uptime7d);
                document.getElementById("kpi-latency").textContent =
                    (data.avgLatencyMs !== null ? data.avgLatencyMs + "ms" : "--") +
                    " / " + (data.p95LatencyMs !== null ? data.p95LatencyMs + "ms" : "--");
                document.getElementById("kpi-requests").textContent = data.requestsToday;
                document.getElementById("kpi-incidents").textContent = data.incidentsLast24h;
            })
            .catch(function () {});
    }

    // ------------------------------------------------------------------
    // Rafraichissement periodique des blocs non temps-reel.
    // ------------------------------------------------------------------
    refreshKpis();
    loadStatusCodes();
    loadTopLists();
    loadServices();
    loadIncidents();

    setInterval(refreshKpis, 30000);
    setInterval(loadStatusCodes, 15000);
    setInterval(loadTopLists, 20000);
    setInterval(loadServices, 20000);
    setInterval(function () {
        var activeRange = document.querySelector(".range-btn.active");
        loadHistory(activeRange ? activeRange.getAttribute("data-range") : "24h");
    }, 60000);
</script>
</body>
</html>
HTML_EOF

chown -R www-data:www-data /var/www/html/dashboard
chown -R root:root /var/lib/blockhash
chmod 750 /var/lib/blockhash

echo ">>> [BlockHash] Provisioning terminé avec succès $(date)"
exit 0
