# Debian Master / Redirector Bootstrap

Script Bash de bootstrap pour transformer un VPS Debian minimal en **Master / Redirector sécurisé**, avec :

- Debian 12 Bookworm ou Debian 13 Trixie
- SSH durci avec protection anti-lockout
- utilisateur administrateur non-root
- `sudo`
- UFW
- Fail2ban
- WireGuard
- Docker officiel
- conteneur Kali Linux optionnel
- aucun port Docker publié automatiquement
- finalisation SSH manuelle après validation d’un second accès

---

## Objectif

Ce script prépare une base Debian propre pour un VPS servant notamment de :

- serveur Master
- redirecteur
- point d’entrée public
- nœud WireGuard
- hôte Docker
- serveur intermédiaire entre une infrastructure privée et Internet
- environnement de laboratoire ou de pentest explicitement autorisé

L’objectif principal est d’obtenir une architecture minimale, contrôlée et durcie, sans risquer de perdre l’accès SSH au VPS pendant l’installation.

---

## Architecture générale

Exemple d’architecture :

```text
Windows 11
   │
   ▼
Kali VM / C2
   │
   ▼
WireGuard
   │
   ▼
Debian VPS
   │
   ├── SSH
   ├── UFW
   ├── Fail2ban
   ├── Docker
   ├── WireGuard
   ├── Kali Docker optionnel
   │
   ▼
Internet
```

Le VPS Debian reste le système principal.

Kali Linux est uniquement disponible sous forme de conteneur Docker optionnel.

---

## Systèmes supportés

Le script est conçu pour :

```text
Debian 12 Bookworm
Debian 13 Trixie
```

Le script refuse volontairement de s’exécuter sur une distribution autre que Debian.

---

## Prérequis

Le VPS doit disposer au minimum de :

- accès root ou sudo
- accès Internet
- Debian minimal
- accès SSH ou console fournisseur
- architecture compatible avec Docker officiel

Exemple de VPS :

```text
2 vCPU
4 Go RAM
40+ Go SSD/NVMe
IPv4 publique
Debian 12/13
```

---

## Installation

Place le script sur le VPS, par exemple :

```bash
nano bootstrap-master.sh
```

Colle le script puis sauvegarde.

Rends-le exécutable :

```bash
chmod +x bootstrap-master.sh
```

Puis lance-le :

```bash
sudo ./bootstrap-master.sh
```

Si tu es déjà connecté directement en root :

```bash
./bootstrap-master.sh
```

---

## Choisir l’utilisateur administrateur

Il est possible de définir explicitement l’utilisateur administrateur :

```bash
ADMIN_USER=neo ./bootstrap-master.sh
```

Si cet utilisateur n’existe pas, le script le créera.

Si le script est lancé avec `sudo`, il utilisera par défaut l’utilisateur ayant lancé :

```bash
sudo ./bootstrap-master.sh
```

Si le script est exécuté directement avec root sans `ADMIN_USER`, il demandera :

```text
Nom de l'utilisateur administrateur [masteradmin] :
```

Exemple :

```text
neo
```

---

## Protection anti-lockout SSH

### Pourquoi ?

Une mauvaise configuration SSH peut rendre un VPS inaccessible.

Par exemple :

```text
PermitRootLogin no
```

appliqué alors qu’aucun utilisateur administrateur fonctionnel n’existe peut provoquer :

```text
Permission denied
Connection closed by SERVER port 22
```

Pour éviter cela, ce script utilise une procédure en deux étapes.

---

## Étape 1 — Safe Mode

Pendant le bootstrap, SSH reste volontairement configuré avec :

```text
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
```

Cela signifie que le script ne désactive jamais automatiquement l’accès root pendant l’installation.

Le but est simple :

```text
ne jamais perdre l'accès au VPS
```

---

## Étape 2 — Tester le nouvel utilisateur

Lorsque le script est terminé, garde ta session actuelle ouverte.

Ouvre un second terminal sur ta machine locale.

Exemple Windows :

```powershell
ssh neo@IP_DU_VPS
```

Exemple :

```powershell
ssh neo@72.61.17.113
```

Puis teste sudo :

```bash
sudo -i
```

Tu dois obtenir une session root.

Vérifie :

```bash
whoami
```

Résultat attendu :

```text
root
```

---

## Étape 3 — Finalisation SSH

Uniquement après avoir validé la nouvelle connexion :

```bash
sudo finalize-ssh-hardening
```

Le script de finalisation demande une confirmation.

Exemple :

```text
La connexion SSH admin fonctionne-t-elle réellement ? [y/N]
```

Répondre :

```text
y
```

Le script peut alors désactiver :

```text
PermitRootLogin
```

Configuration obtenue :

```text
PermitRootLogin no
PubkeyAuthentication yes
```

Si une clé SSH est détectée, il propose également de désactiver :

```text
PasswordAuthentication
```

---

## Authentification SSH par clé

L’utilisation d’une clé SSH est recommandée.

Sur Windows :

```powershell
ssh-keygen -t ed25519
```

Puis afficher la clé publique :

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

Sur Linux :

```bash
cat ~/.ssh/id_ed25519.pub
```

Copie la clé sur le serveur dans :

```text
/home/UTILISATEUR/.ssh/authorized_keys
```

Exemple :

```bash
nano /home/neo/.ssh/authorized_keys
```

Puis :

```bash
chown -R neo:neo /home/neo/.ssh
chmod 700 /home/neo/.ssh
chmod 600 /home/neo/.ssh/authorized_keys
```

Teste ensuite :

```bash
ssh neo@IP_DU_VPS
```

---

## Vérifier la configuration SSH

Pour afficher la configuration réellement appliquée :

```bash
sudo sshd -T | grep -E \
'permitrootlogin|passwordauthentication|pubkeyauthentication'
```

Pendant le Safe Mode :

```text
permitrootlogin yes
passwordauthentication yes
pubkeyauthentication yes
```

Après finalisation complète :

```text
permitrootlogin no
passwordauthentication no
pubkeyauthentication yes
```

si l’authentification par clé a été validée.

---

## Tester la syntaxe SSH

Avant toute modification manuelle :

```bash
sudo sshd -t
```

Si aucune sortie n’apparaît, la syntaxe est valide.

---

## Firewall UFW

Le script réinitialise UFW puis applique :

```text
deny incoming
allow outgoing
deny routed
```

SSH est explicitement autorisé :

```text
22/tcp
```

Vérifier :

```bash
sudo ufw status verbose
```

Résultat typique :

```text
Status: active

Default:
deny (incoming)
allow (outgoing)
deny (routed)
```

---

## WireGuard

Le paquet WireGuard est installé :

```text
wireguard-tools
```

Le port WireGuard n’est volontairement pas ouvert automatiquement.

Lorsque WireGuard sera configuré :

```bash
sudo ufw allow 51820/udp comment 'WireGuard'
```

Puis :

```bash
sudo ufw reload
```

---

## Fail2ban

Fail2ban protège SSH contre les tentatives répétées d’authentification.

Configuration :

```ini
[sshd]

enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
```

Vérification :

```bash
sudo fail2ban-client status sshd
```

---

## Débloquer une IP Fail2ban

Afficher les IP bannies :

```bash
sudo fail2ban-client status sshd
```

Débloquer :

```bash
sudo fail2ban-client set sshd unbanip IP
```

Exemple :

```bash
sudo fail2ban-client set sshd unbanip 1.2.3.4
```

---

## Docker

Le script installe Docker depuis le dépôt officiel Docker pour Debian.

Paquets installés :

```text
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

Vérifier :

```bash
sudo docker --version
```

et :

```bash
sudo docker compose version
```

---

## Configuration Docker

Le daemon Docker utilise notamment :

```json
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true,
  "no-new-privileges": true
}
```

Cette configuration permet notamment de limiter la croissance des logs Docker.

---

## Groupe Docker

L’utilisateur administrateur n’est volontairement pas ajouté automatiquement au groupe :

```text
docker
```

Pourquoi ?

Un utilisateur membre du groupe Docker possède pratiquement des privilèges root sur la machine.

Si tu souhaites malgré tout l’activer :

```bash
sudo usermod -aG docker neo
```

Puis déconnecte/reconnecte la session SSH.

Vérifie :

```bash
groups
```

---

## Arborescence

Le script crée :

```text
/opt/master/
├── backups/
├── config/
├── logs/
└── kali/
    ├── compose.yaml
    └── workspace/
```

Répertoire principal :

```text
/opt/master
```

---

## Kali Linux Docker

Le conteneur Kali est préparé mais volontairement non démarré automatiquement.

Répertoire :

```bash
cd /opt/master/kali
```

Télécharger l’image :

```bash
sudo docker compose pull
```

Démarrer :

```bash
sudo docker compose up -d
```

Vérifier :

```bash
sudo docker ps
```

---

## Entrer dans Kali

```bash
sudo docker exec -it kali-lab bash
```

ou :

```bash
cd /opt/master/kali
sudo docker compose exec kali bash
```

---

## Arrêter Kali

```bash
cd /opt/master/kali
sudo docker compose down
```

---

## Redémarrer Kali

```bash
cd /opt/master/kali
sudo docker compose restart
```

---

## Logs Kali

```bash
cd /opt/master/kali
sudo docker compose logs
```

Suivi temps réel :

```bash
sudo docker compose logs -f
```

---

## Sécurité du conteneur Kali

Le conteneur n’utilise volontairement pas :

```text
privileged: true
```

Il n’utilise pas :

```text
network_mode: host
```

Il ne monte pas :

```text
/var/run/docker.sock
```

Tous les capabilities sont supprimés :

```yaml
cap_drop:
  - ALL
```

Seul :

```yaml
NET_RAW
```

est ajouté.

Le conteneur utilise aussi :

```yaml
security_opt:
  - no-new-privileges:true
```

---

## Aucun port Docker publié

Aucun service du conteneur Kali n’est exposé automatiquement sur Internet.

Il n’existe donc pas de configuration :

```yaml
ports:
  - "XXXX:XXXX"
```

dans le Compose initial.

Toute exposition d’un service doit être décidée explicitement.

---

## Vérifications système

### SSH

```bash
systemctl status ssh
```

---

## Vérification Docker

```bash
systemctl status docker
```

---

## Vérification Fail2ban

```bash
systemctl status fail2ban
```

---

### UFW

```bash
sudo ufw status verbose
```

---

### Services en écoute

```bash
sudo ss -lntup
```

---

### Conteneurs Docker

```bash
sudo docker ps -a
```

---

### Mise à jour Debian

```bash
sudo apt update
sudo apt upgrade -y
```

---

## Mise à jour Docker/Kali

```bash
cd /opt/master/kali

sudo docker compose pull

sudo docker compose up -d
```

---

## Redémarrage du VPS

Une fois les vérifications terminées :

```bash
sudo reboot
```

Attendre quelques secondes puis :

```bash
ssh neo@IP_DU_VPS
```

---

## Séquence d’installation recommandée

```text
1. Installer Debian 12/13
        ↓
2. Se connecter au VPS
        ↓
3. Lancer bootstrap-master.sh
        ↓
4. Laisser SSH en Safe Mode
        ↓
5. Garder la session actuelle ouverte
        ↓
6. Ouvrir un deuxième terminal
        ↓
7. Tester ssh ADMIN@VPS
        ↓
8. Tester sudo -i
        ↓
9. Configurer/tester la clé SSH
        ↓
10. sudo finalize-ssh-hardening
        ↓
11. Tester une troisième connexion SSH
        ↓
12. Fermer l'ancienne session root
```

---

## Important

Ne jamais fermer la session SSH actuellement fonctionnelle avant d’avoir testé une deuxième connexion.

Bonne pratique :

```text
Terminal 1
    ↓
session actuelle conservée

Terminal 2
    ↓
test du nouvel accès SSH

Terminal 3
    ↓
test après hardening
```

---

## Récupération d’urgence

Si SSH devient inaccessible, utiliser la console Web / KVM du fournisseur VPS.

Exemple Hostinger :

```text
hPanel
→ VPS
→ Manage
→ Browser terminal / Console
```

Vérifier :

```bash
cat /etc/ssh/sshd_config.d/10-master-safe.conf
```

ou :

```bash
cat /etc/ssh/sshd_config.d/10-master-hardening.conf
```

Tester :

```bash
sshd -t
```

---

## Réactiver temporairement root

Uniquement depuis la console VPS en cas de récupération :

```bash
sudo nano /etc/ssh/sshd_config.d/10-master-recovery.conf
```

Ajouter :

```text
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
```

Puis :

```bash
sudo sshd -t
sudo systemctl restart ssh
```

Une fois le problème corrigé, supprimer :

```bash
sudo rm /etc/ssh/sshd_config.d/10-master-recovery.conf
```

et revalider :

```bash
sudo sshd -t
sudo systemctl restart ssh
```

---

## Fichiers importants

```text
/etc/ssh/sshd_config
/etc/ssh/sshd_config.d/
/etc/fail2ban/jail.d/sshd.local
/etc/docker/daemon.json
/etc/apt/sources.list.d/docker.sources
/opt/master/
/opt/master/kali/compose.yaml
/usr/local/sbin/finalize-ssh-hardening
```

---

## Commandes utiles

```bash
# État général
systemctl status ssh
systemctl status docker
systemctl status fail2ban

# Firewall
sudo ufw status verbose

# SSH effectif
sudo sshd -T | grep -E \
'permitrootlogin|passwordauthentication|pubkeyauthentication'

# Fail2ban
sudo fail2ban-client status sshd

# Docker
sudo docker ps -a

# Kali
sudo docker exec -it kali-lab bash

# Ports ouverts
sudo ss -lntup

# Adresse IP
ip addr

# Routes
ip route
```

---

## Bonnes pratiques

- conserver une console fournisseur disponible
- utiliser une clé SSH Ed25519
- désactiver root uniquement après validation
- désactiver le mot de passe uniquement après validation de la clé
- ne pas exposer inutilement les ports Docker
- ne pas utiliser `privileged: true` sans nécessité
- ne pas ajouter automatiquement les utilisateurs au groupe Docker
- vérifier régulièrement Fail2ban
- installer les mises à jour Debian
- limiter les services publics
- sauvegarder les configurations importantes
- documenter chaque port ouvert

---

## Usage

Ce projet est destiné à :

- l’administration système
- l’apprentissage
- les environnements de laboratoire
- les CTF
- le pentest autorisé
- les environnements Red Team explicitement autorisés

Il ne doit être utilisé que sur des systèmes et infrastructures pour lesquels tu disposes d’une autorisation explicite.

---

## Résumé

Après installation :

```text
Debian VPS
│
├── SSH anti-lockout
│   └── finalisation manuelle
│
├── utilisateur admin + sudo
│
├── UFW
│
├── Fail2ban
│
├── WireGuard Tools
│
├── Docker CE
│
├── /opt/master
│
└── Kali Linux Docker optionnel
```

Le principe central du script est :

> **Ne jamais sacrifier l’accès administrateur au nom du hardening.**

Le durcissement SSH intervient uniquement après validation réelle d’un second accès fonctionnel.
