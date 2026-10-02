#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# ============================================================
# Debian Master / Redirector bootstrap
#
# Debian 12 Bookworm / Debian 13 Trixie
#
# OBJECTIF IMPORTANT :
#   NE JAMAIS VERROUILLER L'ADMINISTRATEUR HORS DU VPS.
#
# Stratégie SSH :
#   1. créer/vérifier un utilisateur administrateur
#   2. garder ROOT temporairement accessible
#   3. garder PasswordAuthentication actif temporairement
#   4. installer une commande de finalisation SSH
#   5. tester une seconde connexion SSH
#   6. seulement ensuite désactiver root/password
#
# Usage :
#
#   chmod +x bootstrap-master.sh
#   sudo ./bootstrap-master.sh
#
# Ou directement root :
#
#   ./bootstrap-master.sh
#
# Option :
#
#   ADMIN_USER=neo ./bootstrap-master.sh
#
# ============================================================


readonly BASE_DIR="/opt/master"
readonly KALI_DIR="${BASE_DIR}/kali"

readonly KALI_NAME="kali-lab"
readonly KALI_IMAGE="kalilinux/kali-rolling:latest"

readonly SSH_SAFE_CONF="/etc/ssh/sshd_config.d/10-master-safe.conf"
readonly SSH_HARD_CONF="/etc/ssh/sshd_config.d/10-master-hardening.conf"

readonly FINALIZER="/usr/local/sbin/finalize-ssh-hardening"


# ============================================================
# OUTILS
# ============================================================

log() {
    printf '\033[1;34m[+]\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[✓]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[!]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}


trap 'die "Erreur ligne ${LINENO}: ${BASH_COMMAND}"' ERR


# ============================================================
# 0. VÉRIFICATIONS
# ============================================================

[[ $EUID -eq 0 ]] || die "Exécute ce script avec sudo ou root."

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."

. /etc/os-release


[[ "${ID:-}" == "debian" ]] || {
    die "Ce script est prévu uniquement pour Debian. OS détecté : ${ID:-inconnu}"
}


case "${VERSION_ID:-}" in
    12|13)
        ;;
    *)
        warn "Debian ${VERSION_ID:-inconnue} non explicitement testée."
        ;;
esac


log "Système détecté : ${PRETTY_NAME}"


# ============================================================
# 1. ADMINISTRATEUR
# ============================================================

#
# Priorité :
#
# 1. ADMIN_USER fourni explicitement
# 2. utilisateur ayant lancé sudo
# 3. demande interactive si script lancé directement en root
#

if [[ -n "${ADMIN_USER:-}" ]]; then

    ADMIN_USER="${ADMIN_USER}"

elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then

    ADMIN_USER="${SUDO_USER}"

else

    echo
    warn "Le script est exécuté directement en root."
    echo
    echo "Un utilisateur administrateur NON-root doit être préparé."
    echo

    if [[ -t 0 ]]; then

        read -r -p "Nom de l'utilisateur administrateur [masteradmin] : " ADMIN_USER

        ADMIN_USER="${ADMIN_USER:-masteradmin}"

    else

        die "Aucun ADMIN_USER défini. Relance avec : ADMIN_USER=nom ./bootstrap-master.sh"

    fi

fi


#
# Validation simple du nom.
#

if ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "Nom d'utilisateur invalide : ${ADMIN_USER}"
fi


if [[ "$ADMIN_USER" == "root" ]]; then
    die "ADMIN_USER ne peut pas être root."
fi


log "Administrateur principal : ${ADMIN_USER}"


# ============================================================
# 2. BASE DEBIAN
# ============================================================

log "Mise à jour des index APT..."

apt-get update


log "Installation des paquets système..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    jq \
    vim \
    tmux \
    sudo \
    openssh-server \
    ufw \
    fail2ban \
    wireguard-tools \
    unattended-upgrades


# ============================================================
# 3. CRÉATION / VÉRIFICATION ADMIN
# ============================================================

if id "$ADMIN_USER" >/dev/null 2>&1; then

    ok "Utilisateur ${ADMIN_USER} déjà existant."

else

    log "Création de l'utilisateur ${ADMIN_USER}..."

    adduser "$ADMIN_USER"

fi


log "Ajout de ${ADMIN_USER} au groupe sudo..."

usermod -aG sudo "$ADMIN_USER"


ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

[[ -n "$ADMIN_HOME" ]] || die "Impossible de déterminer HOME pour ${ADMIN_USER}"


install -d \
    -m 0700 \
    -o "$ADMIN_USER" \
    -g "$ADMIN_USER" \
    "${ADMIN_HOME}/.ssh"


# ============================================================
# 4. COPIE OPTIONNELLE DES CLÉS ROOT
# ============================================================

#
# Si Hostinger a déjà placé une clé SSH dans /root/.ssh,
# on la copie vers le nouvel administrateur.
#

if [[ -s /root/.ssh/authorized_keys ]]; then

    log "Clé(s) SSH root détectée(s)."

    touch "${ADMIN_HOME}/.ssh/authorized_keys"

    cat /root/.ssh/authorized_keys \
        >> "${ADMIN_HOME}/.ssh/authorized_keys"


    sort -u \
        "${ADMIN_HOME}/.ssh/authorized_keys" \
        -o "${ADMIN_HOME}/.ssh/authorized_keys"


    chown \
        "$ADMIN_USER:$ADMIN_USER" \
        "${ADMIN_HOME}/.ssh/authorized_keys"


    chmod 0600 \
        "${ADMIN_HOME}/.ssh/authorized_keys"


    ok "Clés SSH copiées vers ${ADMIN_USER}."

else

    warn "Aucune clé SSH root détectée."

    warn "PasswordAuthentication restera actif."

fi


# ============================================================
# 5. SSH - MODE SÉCURISÉ ANTI-LOCKOUT
# ============================================================

log "Configuration SSH temporaire anti-lockout..."


install -d -m 0755 /etc/ssh/sshd_config.d


#
# IMPORTANT :
#
# Root n'est PAS désactivé ici.
#
# PasswordAuthentication n'est PAS désactivé ici.
#
# On garantit donc qu'une erreur dans la création du compte admin
# ne rende pas le serveur inaccessible.
#

cat > "$SSH_SAFE_CONF" <<'EOF'

# ============================================================
# MASTER SSH - SAFE MODE
#
# Configuration temporaire.
#
# NE PAS désactiver root tant qu'une connexion admin
# indépendante n'a pas été vérifiée.
# ============================================================

PermitRootLogin yes

PasswordAuthentication yes

PubkeyAuthentication yes

MaxAuthTries 4

LoginGraceTime 30

X11Forwarding no

AllowAgentForwarding no

ClientAliveInterval 300

ClientAliveCountMax 2

EOF


#
# Supprime une éventuelle ancienne configuration dangereuse
# issue d'une précédente version du script.
#

if [[ -f "$SSH_HARD_CONF" ]]; then

    warn "Ancienne configuration SSH hardening détectée."

    rm -f "$SSH_HARD_CONF"

fi


log "Validation configuration SSH..."

sshd -t


log "Redémarrage SSH..."

systemctl restart ssh


systemctl is-active --quiet ssh \
    || die "SSH ne fonctionne plus après redémarrage."


ok "SSH actif."


# ============================================================
# 6. FIREWALL
# ============================================================

log "Configuration UFW..."


ufw --force reset


ufw default deny incoming

ufw default allow outgoing

ufw default deny routed


#
# SSH
#

ufw allow 22/tcp comment 'SSH'


#
# WireGuard
#
# À activer lorsque WG sera configuré :
#
# ufw allow 51820/udp comment 'WireGuard'
#


ufw --force enable


ok "UFW actif."


# ============================================================
# 7. FAIL2BAN
# ============================================================

log "Configuration Fail2ban..."


cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'

[sshd]

enabled = true

maxretry = 5

findtime = 10m

bantime = 1h

EOF


systemctl enable --now fail2ban


systemctl restart fail2ban


ok "Fail2ban actif."


# ============================================================
# 8. DOCKER OFFICIEL DEBIAN
# ============================================================

log "Suppression des éventuels paquets Docker conflictuels..."


for pkg in \
    docker.io \
    docker-compose \
    docker-doc \
    docker-buildx \
    podman-docker
do

    apt-get remove -y "$pkg" 2>/dev/null || true

done


log "Configuration du dépôt Docker officiel..."


install -m 0755 -d /etc/apt/keyrings


curl -fsSL \
    https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc


chmod a+r /etc/apt/keyrings/docker.asc


ARCH="$(dpkg --print-architecture)"


cat > /etc/apt/sources.list.d/docker.sources <<EOF

Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc

EOF


apt-get update


DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin


systemctl enable --now docker


ok "Docker installé."


# ============================================================
# 9. DOCKER DAEMON
# ============================================================

log "Configuration Docker daemon..."


install -d -m 0755 /etc/docker


cat > /etc/docker/daemon.json <<'EOF'

{
    "log-driver": "local",

    "log-opts": {
        "max-size": "20m",
        "max-file": "5"
    },

    "live-restore": true,

    "no-new-privileges": true
}

EOF


systemctl restart docker


systemctl is-active --quiet docker \
    || die "Docker n'est pas actif."


# ============================================================
# 10. ARBORESCENCE MASTER
# ============================================================

log "Création de l'arborescence..."


mkdir -p \
    "${BASE_DIR}/config" \
    "${BASE_DIR}/logs" \
    "${BASE_DIR}/backups" \
    "${KALI_DIR}/workspace"


chmod 750 "$BASE_DIR"


chown -R \
    "$ADMIN_USER:$ADMIN_USER" \
    "$BASE_DIR"


# ============================================================
# 11. KALI DOCKER OPTIONNEL
# ============================================================

log "Création du Compose Kali..."


cat > "${KALI_DIR}/compose.yaml" <<EOF

services:

  kali:

    image: ${KALI_IMAGE}

    container_name: ${KALI_NAME}

    hostname: kali-lab

    restart: unless-stopped

    stdin_open: true

    tty: true

    working_dir: /workspace

    volumes:

      - ./workspace:/workspace


    # Aucun port publié.
    #
    # Aucun :
    #
    # privileged: true
    # network_mode: host
    # /var/run/docker.sock


    cap_drop:

      - ALL


    cap_add:

      - NET_RAW


    security_opt:

      - no-new-privileges:true


    command:

      - sleep

      - infinity

EOF


chown -R \
    "$ADMIN_USER:$ADMIN_USER" \
    "$KALI_DIR"


# ============================================================
# 12. GROUPE DOCKER
# ============================================================

#
# Docker = quasi root.
#
# On ne donne donc PAS automatiquement cet accès à ADMIN_USER.
#

warn "${ADMIN_USER} n'est PAS ajouté automatiquement au groupe docker."


echo
echo "Pour l'autoriser volontairement plus tard :"
echo
echo "    sudo usermod -aG docker ${ADMIN_USER}"
echo


# ============================================================
# 13. SCRIPT DE FINALISATION SSH
# ============================================================

#
# Ce script n'est PAS exécuté automatiquement.
#
# Il sera exécuté seulement lorsque l'utilisateur aura confirmé
# qu'une nouvelle connexion SSH avec ADMIN_USER fonctionne.
#

log "Installation du finaliseur SSH..."


cat > "$FINALIZER" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

ADMIN_USER="${ADMIN_USER}"

SAFE_CONF="${SSH_SAFE_CONF}"

HARD_CONF="${SSH_HARD_CONF}"


if [[ \$EUID -ne 0 ]]; then

    echo "[x] Exécute avec sudo :"
    echo
    echo "    sudo finalize-ssh-hardening"
    echo

    exit 1

fi


echo
echo "=========================================================="
echo "       FINALISATION DU DURCISSEMENT SSH"
echo "=========================================================="
echo
echo "Utilisateur admin : \$ADMIN_USER"
echo
echo "AVANT DE CONTINUER :"
echo
echo "Tu dois avoir TESTÉ dans un SECOND terminal :"
echo
echo "    ssh \$ADMIN_USER@IP_DU_VPS"
echo
echo "Puis :"
echo
echo "    sudo -i"
echo
echo


read -r -p "La connexion SSH admin fonctionne-t-elle réellement ? [y/N] : " ANSWER


case "\$ANSWER" in

    y|Y|yes|YES|oui|OUI)

        ;;

    *)

        echo
        echo "[!] Aucune modification effectuée."
        echo "[!] Root reste accessible."
        echo

        exit 0

        ;;

esac


ADMIN_HOME="\$(getent passwd "\$ADMIN_USER" | cut -d: -f6)"


HAS_KEY="no"


if [[ -s "\${ADMIN_HOME}/.ssh/authorized_keys" ]]; then

    HAS_KEY="yes"

fi


echo

if [[ "\$HAS_KEY" == "yes" ]]; then

    echo "[+] Clé SSH détectée pour \$ADMIN_USER."
    echo

    read -r -p "Désactiver aussi l'authentification par mot de passe ? [y/N] : " DISABLE_PASSWORD

else

    echo "[!] Aucune clé SSH détectée pour \$ADMIN_USER."
    echo "[!] PasswordAuthentication restera actif."
    echo

    DISABLE_PASSWORD="no"

fi


PASSWORD_SETTING="yes"


case "\$DISABLE_PASSWORD" in

    y|Y|yes|YES|oui|OUI)

        PASSWORD_SETTING="no"

        ;;

esac


cat > "\$HARD_CONF" <<HARDENING

# ============================================================
# MASTER SSH - HARDENED MODE
# ============================================================

PermitRootLogin no

PasswordAuthentication \$PASSWORD_SETTING

PubkeyAuthentication yes

MaxAuthTries 4

LoginGraceTime 30

X11Forwarding no

AllowAgentForwarding no

ClientAliveInterval 300

ClientAliveCountMax 2

HARDENING


#
# L'ancien safe mode doit disparaître pour éviter
# les ambiguïtés de configuration.
#

rm -f "\$SAFE_CONF"


echo "[+] Vérification sshd..."


if ! sshd -t; then

    echo
    echo "[x] Configuration SSH invalide."
    echo "[x] RESTAURATION du mode sécurisé."
    echo

    rm -f "\$HARD_CONF"


    cat > "\$SAFE_CONF" <<'SAFE'

PermitRootLogin yes

PasswordAuthentication yes

PubkeyAuthentication yes

MaxAuthTries 4

LoginGraceTime 30

X11Forwarding no

AllowAgentForwarding no

ClientAliveInterval 300

ClientAliveCountMax 2

SAFE


    sshd -t

    systemctl restart ssh

    exit 1

fi


systemctl restart ssh


if ! systemctl is-active --quiet ssh; then

    echo
    echo "[x] SSH ne fonctionne pas."
    echo "[x] RESTAURATION automatique."
    echo

    rm -f "\$HARD_CONF"


    cat > "\$SAFE_CONF" <<'SAFE'

PermitRootLogin yes

PasswordAuthentication yes

PubkeyAuthentication yes

MaxAuthTries 4

LoginGraceTime 30

X11Forwarding no

AllowAgentForwarding no

ClientAliveInterval 300

ClientAliveCountMax 2

SAFE


    sshd -t

    systemctl restart ssh

    exit 1

fi


echo
echo "=========================================================="
echo "SSH DURCI AVEC SUCCÈS"
echo "=========================================================="
echo
echo "PermitRootLogin        : no"
echo "PasswordAuthentication : \$PASSWORD_SETTING"
echo "PubkeyAuthentication   : yes"
echo
echo "Utilisateur SSH : \$ADMIN_USER"
echo
echo "NE FERME PAS TA SESSION COURANTE avant d'avoir testé"
echo "une nouvelle connexion SSH."
echo

EOF


chmod 0750 "$FINALIZER"


# ============================================================
# 14. TESTS
# ============================================================

log "Tests finaux..."


docker --version

docker compose version


systemctl is-active --quiet docker \
    || die "Docker n'est pas actif."


systemctl is-active --quiet fail2ban \
    || die "Fail2ban n'est pas actif."


systemctl is-active --quiet ssh \
    || die "SSH n'est pas actif."


sshd -t


ok "Tests terminés."


# ============================================================
# 15. RÉSUMÉ
# ============================================================

echo
echo
echo "=========================================================="
echo "             DEBIAN MASTER INITIALISÉ"
echo "=========================================================="
echo
echo "OS            : ${PRETTY_NAME}"
echo "Admin         : ${ADMIN_USER}"
echo "Docker        : $(docker --version)"
echo "Base          : ${BASE_DIR}"
echo
echo "----------------------------------------------------------"
echo "SSH - IMPORTANT"
echo "----------------------------------------------------------"
echo
echo "Le serveur est actuellement volontairement en mode"
echo "ANTI-LOCKOUT :"
echo
echo "    PermitRootLogin yes"
echo "    PasswordAuthentication yes"
echo "    PubkeyAuthentication yes"
echo
echo
echo "1. NE FERME PAS LA SESSION ACTUELLE."
echo
echo "2. Ouvre un deuxième terminal Windows."
echo
echo "3. Teste :"
echo
echo "    ssh ${ADMIN_USER}@IP_DU_VPS"
echo
echo "4. Puis :"
echo
echo "    sudo -i"
echo
echo "5. UNIQUEMENT si tout fonctionne :"
echo
echo "    sudo finalize-ssh-hardening"
echo
echo "----------------------------------------------------------"
echo
echo "Firewall :"
echo
echo "    sudo ufw status verbose"
echo
echo "Fail2ban :"
echo
echo "    sudo fail2ban-client status sshd"
echo
echo "SSH :"
echo
echo "    sudo sshd -T | grep -E \\"
echo "      'permitrootlogin|passwordauthentication|pubkeyauthentication'"
echo
echo "Docker :"
echo
echo "    sudo docker ps"
echo
echo "Kali n'est volontairement PAS démarré."
echo
echo "Pour le démarrer :"
echo
echo "    cd ${KALI_DIR}"
echo "    sudo docker compose pull"
echo "    sudo docker compose up -d"
echo
echo "=========================================================="