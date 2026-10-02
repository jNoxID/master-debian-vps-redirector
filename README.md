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
