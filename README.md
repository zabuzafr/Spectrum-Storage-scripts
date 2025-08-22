# Spectrum-Storage-scripts

# TSM Backup Volume Reporter

Script Perl pour générer des rapports de volumétrie de sauvegardes TSM (IBM Spectrum Protect) avec graphiques et statistiques.

## 📊 Fonctionnalités

- **Analyse de volumétrie** sur 7 ou 30 derniers jours
- **Graphiques PNG** générés automatiquement
- **Rapports HTML** détaillés avec statistiques
- **Sortie console** avec visualisation ASCII
- **Envoi email automatique** (optionnel)
- **Support multi-plateformes** (AIX, Linux, Windows)

## 📋 Prérequis

### Prérequis système
- Perl 5.10 ou supérieur
- Accès à la ligne de commande TSM `dsmadmc`
- Serveur TSM accessible

### Modules Perl requis
```bash
# Modules core
DBI
GD::Graph
GD::Graph::bars
GD::Graph::Data
Text::Table
File::Path
POSIX
Excel::Writer::XLSX

### Sur AIX:
/usr/bin/perl -MCPAN -e shell
install DBI
install GD::Graph
install Text::Table
install Excel::Writer::XLSX


### Sur Linux (RedHat/CentOS):
yum install perl-GD perl-GDGraph perl-DBI
cpan install Text::Table
cpan install Excel::Writer::XLSX

### Sur Windows (ActivePerl):
ppm install GD::Graph
ppm install Text-Table
ppm install Excel::Writer::XLSX

