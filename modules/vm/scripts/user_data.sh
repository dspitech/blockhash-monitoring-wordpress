#!/bin/bash
##############################################################################
# user_data.sh — Script de provisioning cloud-init exécuté au premier
# démarrage de la VM Web BlockHash (Ubuntu 24.04 LTS).
#
# GESTION DES SECRETS : ce script ne contient AUCUN mot de passe, clé SSH ou
# identifiant de base de données en clair. Les seules valeurs interpolées
# par Terraform (templatefile) ci-dessous sont NON SENSIBLES :
#   - key_vault_name                    : nom du Key Vault à interroger
#   - mysql_admin_login_secret_name     : NOM du secret (pas sa valeur)
#   - mysql_admin_password_secret_name  : NOM du secret (pas sa valeur)
#   - alert_webhook_url_secret_name     : NOM du secret (pas sa valeur)
#   - mysql_database_name               : nom de la base ("wordpress")
#   - alert_email                       : adresse email de destination
#
# Les VALEURS secrètes elles-mêmes (login/mot de passe MySQL, webhook) sont
# récupérées UNIQUEMENT à l'exécution, depuis Azure Key Vault, en utilisant
# l'identité managée système (Managed Identity) de la VM via le service de
# métadonnées IMDS (http://169.254.169.254). Elles ne transitent jamais par
# le state Terraform sous cette forme, ni par un fichier de configuration
# en clair sur la VM.
#
# ARCHITECTURE MySQL (v2) : Azure Database for MySQL Flexible Server a été
# abandonné (restriction "ProvisionNotSupportedForRegion" constatée sur
# l'abonnement Azure for Students, indépendante de la région). MySQL Server
# 8.x est donc installé et configuré DIRECTEMENT SUR CETTE VM (127.0.0.1),
# et WordPress s'y connecte en local plutôt qu'à un serveur managé distant.
# Le login/mot de passe de l'utilisateur MySQL applicatif restent générés
# dynamiquement par Terraform et stockés dans Key Vault, exactement comme
# avant : seul change ce à quoi ils servent (créer un utilisateur MySQL
# local au lieu de s'authentifier à un serveur managé).
#
# Étapes réalisées :
#   1. Mise à jour système & installation des dépendances (dont jq, mysql-server)
#   2. Mise en place de l'accès Key Vault (config + script kv-get-secret.sh)
#   3. Installation et configuration de MySQL Server LOCAL (base + utilisateur)
#   4. Configuration Nginx (WordPress + alias /dashboard + proxy WebSocket)
#   5. Déploiement et configuration de WordPress (connexion à MySQL local)
#   6. Script de monitoring enrichi (monitor.sh) + script de test (test_5xx.sh)
#   7. Planification Cron du monitoring (toutes les 5 minutes)
#   8. Backend Node.js WebSockets (dashboard/server.js) piloté par pm2
#   9. Frontend Dashboard (dashboard/index.html) — Dark Mode Glassmorphism
##############################################################################

set -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo ">>> [BlockHash] Démarrage du provisioning $(date)"

##############################################################################
# 1. MISE A JOUR SYSTEME & INSTALLATION DES DEPENDANCES
##############################################################################
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/9] Mise à jour du système..."
apt-get update -y
apt-get upgrade -y

echo ">>> [1/9] Installation de Nginx, PHP 8.3, MySQL Server, Node.js, NPM, Mailutils, Curl, jq..."
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
    nodejs \
    npm \
    mailutils \
    curl \
    jq \
    unzip \
    bc \
    python3

npm install -g pm2

##############################################################################
# 2. ACCES AZURE KEY VAULT VIA L'IDENTITE MANAGEE DE LA VM
##############################################################################
echo ">>> [2/9] Mise en place de l'accès à Key Vault (identité managée)..."

mkdir -p /etc/blockhash

# Fichier de configuration NON SECRET : ne contient que des NOMS (Key Vault,
# secrets), jamais de valeur sensible. Lisible uniquement par root.
cat > /etc/blockhash/keyvault.env << ENV_EOF
KEY_VAULT_NAME=${key_vault_name}
MYSQL_LOGIN_SECRET_NAME=${mysql_admin_login_secret_name}
MYSQL_PASSWORD_SECRET_NAME=${mysql_admin_password_secret_name}
ALERT_WEBHOOK_SECRET_NAME=${alert_webhook_url_secret_name}
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
echo ">>> [3/9] Installation et configuration de MySQL Server local..."

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

echo ">>> [3/9] Récupération des identifiants MySQL depuis Azure Key Vault..."

# Récupérés UNE SEULE FOIS ici, puis réutilisés à l'étape 5 (wp-config.php)
# via ces mêmes variables d'environnement exportées — évite un second aller-
# retour vers Key Vault pour la même information.
source /etc/blockhash/keyvault.env

export MYSQL_ADMIN_LOGIN
export MYSQL_ADMIN_PASSWORD
MYSQL_ADMIN_LOGIN=$(/usr/local/bin/kv-get-secret.sh "$MYSQL_LOGIN_SECRET_NAME" 20 15)
MYSQL_ADMIN_PASSWORD=$(/usr/local/bin/kv-get-secret.sh "$MYSQL_PASSWORD_SECRET_NAME" 20 15)

echo ">>> [3/9] Création de la base '${mysql_database_name}' et de l'utilisateur applicatif local..."

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

echo ">>> [3/9] MySQL Server local opérationnel (base '${mysql_database_name}' prête)."

##############################################################################
# 4. CONFIGURATION NGINX
##############################################################################
echo ">>> [4/9] Configuration du virtual host Nginx..."

cat > /etc/nginx/sites-available/blockhash << 'NGINX_EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html;

    client_max_body_size 64M;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    location /dashboard {
        alias /var/www/html/dashboard;
        try_files $uri $uri/ /dashboard/index.html;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location ~* /(wp-config\.php|\.htaccess) {
        deny all;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/blockhash /etc/nginx/sites-enabled/blockhash
rm -f /etc/nginx/sites-enabled/default

systemctl enable nginx
systemctl enable php8.3-fpm
systemctl restart php8.3-fpm
systemctl restart nginx

##############################################################################
# 5. DEPLOIEMENT & CONFIGURATION DE WORDPRESS (connexion MySQL locale)
##############################################################################
echo ">>> [5/9] Téléchargement et déploiement de WordPress..."

cd /tmp
curl -sSL -O https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

rm -rf /var/www/html/*
cp -r /tmp/wordpress/* /var/www/html/
rm -rf /tmp/wordpress /tmp/latest.tar.gz

cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

echo ">>> [5/9] Injection des identifiants MySQL dans wp-config.php..."

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
# directement par Terraform. DB_HOST reste "localhost" — valeur par défaut
# de wp-config-sample.php — puisque MySQL tourne désormais SUR CETTE VM
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

mkdir -p /var/www/html/dashboard
chown -R www-data:www-data /var/www/html
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

##############################################################################
# 6. SCRIPT DE MONITORING ENRICHI (monitor.sh) + SCRIPT DE TEST (test_5xx.sh)
##############################################################################
echo ">>> [6/9] Installation du script de monitoring /usr/local/bin/monitor.sh..."

cat > /usr/local/bin/monitor.sh << 'MONITOR_EOF'
#!/bin/bash
##############################################################################
# monitor.sh — Script de surveillance applicative & système pour BlockHash.
#
# Exécuté toutes les 5 minutes par cron (voir /etc/cron.d/blockhash-monitor).
# Le webhook d'alerte n'est JAMAIS stocké en clair sur disque : il est
# récupéré depuis Key Vault via kv-get-secret.sh, uniquement au moment où
# une alerte doit effectivement être envoyée (voir send_alert ci-dessous).
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

echo ">>> [6/9] Installation du script de test d'alerte /usr/local/bin/test_5xx.sh..."

cat > /usr/local/bin/test_5xx.sh << 'TEST_EOF'
#!/bin/bash
##############################################################################
# test_5xx.sh — Déclenche artificiellement des erreurs HTTP 500 afin de
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

##############################################################################
# 7. PLANIFICATION CRON DU MONITORING (toutes les 5 minutes)
##############################################################################
echo ">>> [7/9] Planification cron de monitor.sh..."

cat > /etc/cron.d/blockhash-monitor << 'CRON_EOF'
*/5 * * * * root /usr/local/bin/monitor.sh >> /var/log/blockhash-monitor.log 2>&1
CRON_EOF

chmod 644 /etc/cron.d/blockhash-monitor
touch /var/log/blockhash-monitor.log

##############################################################################
# 8. BACKEND NODE.JS WEBSOCKETS (dashboard/server.js)
##############################################################################
echo ">>> [8/9] Déploiement du backend Node.js (dashboard/server.js)..."

mkdir -p /var/www/html/dashboard

cat > /var/www/html/dashboard/package.json << 'PKG_EOF'
{
  "name": "blockhash-dashboard-server",
  "version": "1.0.0",
  "description": "Backend WebSocket temps reel pour le dashboard de monitoring BlockHash",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "socket.io": "^4.7.5"
  }
}
PKG_EOF

cat > /var/www/html/dashboard/server.js << 'SERVER_EOF'
// ============================================================================
// server.js — Backend WebSocket temps reel du Dashboard BlockHash
//
// Ce fichier n'utilise aucun template literal JavaScript (backticks avec
// interpolation) afin d'eviter tout conflit avec le mecanisme
// d'interpolation "templatefile" de Terraform qui a genere ce script
// cloud-init. Toutes les concatenations de chaines utilisent l'operateur "+".
// ============================================================================

var express = require("express");
var http = require("http");
var os = require("os");
var fs = require("fs");
var child_process = require("child_process");
var socketio = require("socket.io");

var app = express();
var server = http.createServer(app);
var io = socketio(server, {
    cors: { origin: "*" }
});

var PORT = 3000;
var NGINX_ACCESS_LOG = "/var/log/nginx/access.log";

app.use(express.static(__dirname));

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
                io.emit("metrics", payload);
            });
        });
    });
}, 3000);

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
                io.emit("logline", line);
            }
        }
    });

    tail.on("error", function (err) {
        console.log("Erreur tail -F : " + err.message);
    });
}

io.on("connection", function (socket) {
    console.log("Client dashboard connecte : " + socket.id);

    socket.on("disconnect", function () {
        console.log("Client dashboard deconnecte : " + socket.id);
    });

    socket.on("trigger_5xx_test", function () {
        child_process.exec("/usr/local/bin/test_5xx.sh", function (err, stdout) {
            io.emit("test_5xx_result", { success: !err, output: stdout || "" });
        });
    });
});

startLogStream();

server.listen(PORT, function () {
    console.log("Serveur dashboard BlockHash demarre sur le port " + PORT);
});
SERVER_EOF

cd /var/www/html/dashboard
npm install --production

pm2 start server.js --name blockhash-dashboard
pm2 startup systemd -u root --hp /root > /tmp/pm2-startup.log 2>&1 || true
bash /tmp/pm2-startup.log > /dev/null 2>&1 || true
pm2 save

##############################################################################
# 9. FRONTEND DASHBOARD (dashboard/index.html) — Dark Glassmorphism Premium
##############################################################################
echo ">>> [9/9] Déploiement du frontend dashboard/index.html..."

cat > /var/www/html/dashboard/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BlockHash — Dashboard de Monitoring</title>

<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
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
    .status-dot {
        width: 10px;
        height: 10px;
        border-radius: 9999px;
        display: inline-block;
        box-shadow: 0 0 8px currentColor;
    }
    #log-terminal {
        background: rgba(0, 0, 0, 0.55);
        font-family: 'Courier New', monospace;
        font-size: 0.78rem;
        line-height: 1.35rem;
        overflow-y: auto;
    }
    #log-terminal::-webkit-scrollbar { width: 8px; }
    #log-terminal::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15); border-radius: 4px; }
</style>
</head>
<body class="p-6 md:p-10">

    <header class="flex flex-col md:flex-row md:items-center md:justify-between mb-8 gap-4">
        <div>
            <h1 class="text-3xl font-bold text-white tracking-tight">BlockHash <span class="text-indigo-400">Ops</span></h1>
            <p class="text-slate-400 text-sm mt-1">Dashboard de monitoring temps reel — Infrastructure Azure</p>
        </div>
        <div class="flex items-center gap-3">
            <span id="connection-indicator" class="status-dot bg-slate-500 text-slate-500"></span>
            <span id="connection-label" class="text-sm text-slate-400">Connexion...</span>
        </div>
    </header>

    <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5 mb-8">

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-slate-400 text-sm">Statut Web</span>
                <i data-lucide="globe" class="w-5 h-5 text-indigo-400"></i>
            </div>
            <p id="web-status-value" class="text-2xl font-bold mt-3 text-white">--</p>
            <p id="web-status-sub" class="text-xs text-slate-500 mt-1">En attente de donnees</p>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-slate-400 text-sm">CPU</span>
                <i data-lucide="cpu" class="w-5 h-5 text-emerald-400"></i>
            </div>
            <p id="cpu-value" class="text-2xl font-bold mt-3 text-white">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="cpu-bar" class="bg-emerald-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-slate-400 text-sm">RAM</span>
                <i data-lucide="memory-stick" class="w-5 h-5 text-amber-400"></i>
            </div>
            <p id="ram-value" class="text-2xl font-bold mt-3 text-white">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="ram-bar" class="bg-amber-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>

        <div class="glass-card p-5">
            <div class="flex items-center justify-between">
                <span class="text-slate-400 text-sm">Disque</span>
                <i data-lucide="hard-drive" class="w-5 h-5 text-rose-400"></i>
            </div>
            <p id="disk-value" class="text-2xl font-bold mt-3 text-white">--%</p>
            <div class="w-full bg-slate-700/40 rounded-full h-1.5 mt-3">
                <div id="disk-bar" class="bg-rose-400 h-1.5 rounded-full" style="width:0%"></div>
            </div>
        </div>
    </section>

    <section class="grid grid-cols-1 lg:grid-cols-3 gap-5 mb-8">
        <div class="glass-card p-5 lg:col-span-2">
            <h2 class="text-white font-semibold mb-3">Evolution CPU (temps reel)</h2>
            <canvas id="cpu-chart" height="90"></canvas>
        </div>

        <div class="glass-card p-5 flex flex-col gap-4">
            <h2 class="text-white font-semibold">Actions</h2>
            <button id="btn-test-5xx"
                class="w-full flex items-center justify-center gap-2 bg-rose-500/20 hover:bg-rose-500/30 border border-rose-400/30 text-rose-300 rounded-lg py-2.5 transition">
                <i data-lucide="zap" class="w-4 h-4"></i>
                Lancer un test d'erreur 5xx
            </button>
            <p id="test-5xx-result" class="text-xs text-slate-500"></p>

            <div class="mt-auto text-xs text-slate-500">
                <p>Hote : <span id="hostname-value">--</span></p>
                <p>Derniere mise a jour : <span id="last-update-value">--</span></p>
            </div>
        </div>
    </section>

    <section class="glass-card p-5">
        <div class="flex items-center justify-between mb-3">
            <h2 class="text-white font-semibold flex items-center gap-2">
                <i data-lucide="terminal" class="w-4 h-4"></i>
                Logs Nginx en direct
            </h2>
            <button id="btn-clear-logs" class="text-xs text-slate-400 hover:text-white transition">Effacer</button>
        </div>
        <div id="log-terminal" class="rounded-lg p-4 h-64"></div>
    </section>

<script>
    lucide.createIcons();

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

    var maxPoints = 30;
    var cpuLabels = [];
    var cpuData = [];

    var ctx = document.getElementById("cpu-chart").getContext("2d");
    var cpuChart = new Chart(ctx, {
        type: "line",
        data: {
            labels: cpuLabels,
            datasets: [{
                label: "CPU %",
                data: cpuData,
                borderColor: "#34d399",
                backgroundColor: "rgba(52, 211, 153, 0.15)",
                tension: 0.35,
                fill: true,
                pointRadius: 0
            }]
        },
        options: {
            responsive: true,
            animation: false,
            scales: {
                y: { min: 0, max: 100, ticks: { color: "#94a3b8" }, grid: { color: "rgba(255,255,255,0.05)" } },
                x: { ticks: { color: "#64748b", maxTicksLimit: 6 }, grid: { display: false } }
            },
            plugins: { legend: { display: false } }
        }
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

        var label = new Date(data.timestamp).toLocaleTimeString();
        cpuLabels.push(label);
        cpuData.push(data.cpu);
        if (cpuLabels.length > maxPoints) {
            cpuLabels.shift();
            cpuData.shift();
        }
        cpuChart.update();
    });

    var logTerminal = document.getElementById("log-terminal");
    var maxLogLines = 300;

    socket.on("logline", function (line) {
        var lineEl = document.createElement("div");

        if (/\s5\d{2}\s/.test(line)) {
            lineEl.className = "text-rose-400";
        } else if (/\s4\d{2}\s/.test(line)) {
            lineEl.className = "text-amber-400";
        } else {
            lineEl.className = "text-slate-400";
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

    document.getElementById("btn-test-5xx").addEventListener("click", function () {
        document.getElementById("test-5xx-result").textContent = "Test en cours...";
        socket.emit("trigger_5xx_test");
    });

    socket.on("test_5xx_result", function (result) {
        var el = document.getElementById("test-5xx-result");
        el.textContent = result.success
            ? "Test termine avec succes : verifiez vos canaux d'alerte."
            : "Le test a rencontre une erreur.";
    });
</script>
</body>
</html>
HTML_EOF

chown -R www-data:www-data /var/www/html/dashboard

echo ">>> [BlockHash] Provisioning terminé avec succès $(date)"
exit 0
