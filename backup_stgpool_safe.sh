#!/bin/ksh

# =============================================================================
# Script sécurisé pour backup stgpool TSM (Spectrum Protect)
# Vérifie l'absence de processus EXPIRED/RECLAIM/MIGRATION avant execution.
# Utilise un fichier de mot de passe sécurisé.
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration (À ADAPTER à votre environnement)
# -----------------------------------------------------------------------------
SERVERNAME=$(hostname)
TSM_INSTANCE="dsmserv"       # Nom de l'instance TSM
ADMIN_USER="admin"           # Utilisateur admin TSM
PASSWORD_FILE="/etc/tsm/tsm.passwd" # Fichier contenant le mot de passe
LOG_FILE="/var/log/tsm/backup_stgpool.log" # Fichier de log principal
LOCK_FILE="/tmp/backup_stgpool_safe.lock"  # Fichier verrou anti-execution concurrente
TIMESTAMP=$(date +%Y-%m-%d_%H:%M:%S)

# Pools par défaut (peuvent être overridés par les arguments)
DEFAULT_PRIMARY_POOL="DISK_POOL"
DEFAULT_COPY_POOL="TAPE_COPY_POOL"
DEFAULT_PROCESS_NUMBER=4

# Timeout pour la vérification des processus (en secondes)
WAIT_TIMEOUT=7200   # 2 heures maximum
SLEEP_INTERVAL=300  # Attendre 5 minutes entre chaque vérification

# -----------------------------------------------------------------------------
# Fonctions
# -----------------------------------------------------------------------------
function log_message {
    echo "$TIMESTAMP - $1" | tee -a $LOG_FILE
}

function cleanup {
    # Fonction de nettoyage pour supprimer le lock file à la sortie du script
    rm -f "$LOCK_FILE"
    log_message "Nettoyage effectué - Lock file supprimé."
}

function run_dsmadmc {
    # Fonction pour exécuter des commandes dsmadmc de manière sécurisée
    CMD="$@"
    dsmadmc -id=$ADMIN_USER -passwordfile=$PASSWORD_FILE -dataonly=yes -commadelimited -servername=$SERVERNAME "$CMD" 2>> $LOG_FILE
    return $?
}

function check_critical_processes {
    # Vérifie s'il y a des processus EXPIRE, RECLAIM ou MIGRATION en cours
    log_message "Vérification des processus critiques (EXPIRE, RECLAIM, MIGRATION)..."

    # Query des processus actifs
    PROCESS_LIST=$(run_dsmadmc "query process")
    if [ $? -ne 0 ]; then
        log_message "ERREUR: La commande 'query process' a échoué."
        return 2
    fi

    CRITICAL_PROCESS_FOUND=$(echo "$PROCESS_LIST" | grep -i -E "(Expiration|Reclaim|Migration)" | head -n 1)

    if [[ -n "$CRITICAL_PROCESS_FOUND" ]]; then
        log_message "Processus critique detecté : $CRITICAL_PROCESS_FOUND"
        return 1
    else
        log_message "Aucun processus critique detecté."
        return 0
    fi
}

function wait_for_critical_processes {
    # Attend que les processus critiques se terminent, avec timeout
    local START_TIME=$(date +%s)
    local ELAPSED_TIME=0

    log_message "Attente de la fin des processus critiques (Timeout: $WAIT_TIMEOUT secondes)..."

    while [ $ELAPSED_TIME -lt $WAIT_TIMEOUT ]; do
        check_critical_processes
        if [ $? -eq 0 ]; then
            log_message "Aucun processus critique en cours. Lancement du backup autorisé."
            return 0
        fi

        log_message "Processus critique(s) encore en cours. Nouvelle tentative dans $SLEEP_INTERVAL secondes..."
        sleep $SLEEP_INTERVAL

        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    done

    log_message "TIMEOUT: Délai d'attente dépassé ($WAIT_TIMEOUT secondes). Arrêt du script."
    return 1
}

# -----------------------------------------------------------------------------
# Début du Script Principal
# -----------------------------------------------------------------------------

# Gestion des signaux pour le nettoyage
trap cleanup EXIT INT TERM

log_message "=== Début de l'exécution du script de backup sécurisé ==="

# -----------------------------------------------------------------------------
# Validation initiale
# -----------------------------------------------------------------------------

# Vérification de l'utilisateur (optionnel, décommentez si nécessaire)
# if [ "$(whoami)" != "tsminst1" ]; then
#     log_message "ERREUR: Ce script doit être exécuté par l'utilisateur tsminst1."
#     exit 1
# fi

# Vérification de l'existence du fichier de mot de passe
if [ ! -f "$PASSWORD_FILE" ]; then
    log_message "ERREUR: Fichier de mot de passe $PASSWORD_FILE introuvable."
    exit 1
fi

# Vérification des permissions du fichier de mot de passe
if [ $(stat -f %Lp "$PASSWORD_FILE") -ne 600 ]; then
    log_message "ERREUR: Le fichier $PASSWORD_FILE n'a pas les permissions 600."
    exit 1
fi

# Gestion des arguments
PRIMARY_POOL=${1:-$DEFAULT_PRIMARY_POOL}
COPY_POOL=${2:-$DEFAULT_COPY_POOL}
PROCESS_NUMBER=${3:-$DEFAULT_PROCESS_NUMBER}

log_message "Configuration:"
log_message "  - Pool Primaire: $PRIMARY_POOL"
log_message "  - Pool de Copie: $COPY_POOL"
log_message "  - Nombre de Processes: $PROCESS_NUMBER"
log_message "  - Serveur TSM: $SERVERNAME"

# -----------------------------------------------------------------------------
# Gestion de l'exécution concurrente (Lock File)
# -----------------------------------------------------------------------------
if [ -f "$LOCK_FILE" ]; then
    log_message "ERREUR: Le script est déjà en cours d'exécution (Lock file existant: $LOCK_FILE)."
    exit 1
fi

# Création du lock file
echo $$ > "$LOCK_FILE"
if [ $? -ne 0 ]; then
    log_message "ERREUR: Impossible de créer le lock file $LOCK_FILE."
    exit 1
fi
log_message "Lock file créé: $LOCK_FILE"

# -----------------------------------------------------------------------------
# Étape 1: Vérification et attente des processus critiques
# -----------------------------------------------------------------------------
wait_for_critical_processes
WAIT_RC=$?

if [ $WAIT_RC -ne 0 ]; then
    log_message "Arrêt du script sans avoir lancé le backup."
    exit $WAIT_RC
fi

# -----------------------------------------------------------------------------
# Étape 2: Lancement du backup stgpool
# -----------------------------------------------------------------------------
log_message "Lancement de la commande: backup stgpool $PRIMARY_POOL $COPY_POOL -processnumber=$PROCESS_NUMBER"

BACKUP_CMD="backup stgpool $PRIMARY_POOL $COPY_POOL -processnumber=$PROCESS_NUMBER"

# Exécution de la commande de backup
dsmadmc -id=$ADMIN_USER -passwordfile=$PASSWORD_FILE -servername=$SERVERNAME "$BACKUP_CMD" 2>&1 | tee -a $LOG_FILE

# Capture du code de retour de dsmadmc
BACKUP_RC=${PIPESTATUS[0]}

if [[ $BACKUP_RC -eq 0 ]]; then
    log_message "SUCCÈS: Backup stgpool terminé avec succès."
else
    log_message "ERREUR: Le backup stgpool a échoué avec le code: $BACKUP_RC"
fi

# -----------------------------------------------------------------------------
# Fin du Script
# -----------------------------------------------------------------------------
log_message "=== Fin de l'exécution du script (Code de retour: $BACKUP_RC) ==="
exit $BACKUP_RC
