#!/bin/ksh

# =============================================================================
# Script TSM : Analyse détaillée de l'utilisation d'un Storage Pool
# Affiche tous les nodes avec leurs management classes pour backup/archive
# qui stockent des données dans le pool spécifié.
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SERVERNAME=$(hostname)
ADMIN_USER="admin"
PASSWORD_FILE="/etc/tsm/tsm.passwd" # Fichier de mot de passe sécurisé
OUTPUT_FILE="/tmp/pool_usage_report_$(date +%Y%m%d_%H%M%S).csv"
TEMP_DIR="/tmp/tsm_query_$$"

# -----------------------------------------------------------------------------
# Fonctions
# -----------------------------------------------------------------------------
function cleanup {
    rm -rf "$TEMP_DIR"
    exit
}

function run_dsmadmc {
    CMD="$@"
    dsmadmc -id=$ADMIN_USER -passwordfile=$PASSWORD_FILE -dataonly=yes -commadelimited -servername=$SERVERNAME "$CMD" 2>/dev/null
    return $?
}

function log_error {
    echo "ERROR: $1" >&2
    cleanup
}

# -----------------------------------------------------------------------------
# Début du script
# -----------------------------------------------------------------------------
trap cleanup INT TERM

# Validation des arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <storage_pool_name>"
    echo "Example: $0 DISK_POOL"
    exit 1
fi

POOL_NAME=$1
mkdir -p "$TEMP_DIR"

# -----------------------------------------------------------------------------
# Validation initiale
# -----------------------------------------------------------------------------
echo "Vérification de l'existence du pool $POOL_NAME..."
POOL_EXISTS=$(run_dsmadmc "query stgpool $POOL_NAME" | head -1)
if [ -z "$POOL_EXISTS" ]; then
    log_error "Le pool $POOL_NAME n'existe pas ou n'est pas accessible."
fi

# -----------------------------------------------------------------------------
# 1. Récupérer tous les fichiers contenus dans le pool spécifié
# -----------------------------------------------------------------------------
echo "Recherche des fichiers dans le pool $POOL_NAME..."
run_dsmadmc "query content stgpool=$POOL_NAME" > "$TEMP_DIR/content.txt"

if [ ! -s "$TEMP_DIR/content.txt" ]; then
    echo "Aucune donnée trouvée dans le pool $POOL_NAME."
    cleanup
fi

# -----------------------------------------------------------------------------
# 2. Extraire les noms de nodes uniques
# -----------------------------------------------------------------------------
echo "Extraction des nodes..."
awk -F, 'NR>1 {print $1}' "$TEMP_DIR/content.txt" | sort -u > "$TEMP_DIR/nodes.txt"

# -----------------------------------------------------------------------------
# 3. Pour chaque node, récupérer les management classes de backup et archive
# -----------------------------------------------------------------------------
echo "Génération du rapport..."
echo "Node Name,Management Class Type,Management Class Name,Policy Domain,Policy Set,Files in Pool" > "$OUTPUT_FILE"

NODE_COUNT=0
while read -r NODE_NAME; do
    [ -z "$NODE_NAME" ] && continue
    ((NODE_COUNT++))
    
    echo "Traitement du node: $NODE_NAME ($NODE_COUNT)..."
    
    # Récupérer les management classes de backup
    run_dsmadmc "query nodedata $NODE_NAME" | grep -i "backup" > "$TEMP_DIR/node_backup_$NODE_NAME.txt"
    
    # Récupérer les management classes d'archive  
    run_dsmadmc "query nodedata $NODE_NAME" | grep -i "archive" > "$TEMP_DIR/node_archive_$NODE_NAME.txt"
    
    # Compter le nombre de fichiers par node dans le pool
    FILE_COUNT=$(grep -c "^$NODE_NAME," "$TEMP_DIR/content.txt")
    
    # Traitement des management classes de backup
    if [ -s "$TEMP_DIR/node_backup_$NODE_NAME.txt" ]; then
        while IFS= read -r LINE; do
            MC_NAME=$(echo "$LINE" | awk '{print $1}')
            DOMAIN=$(echo "$LINE" | awk '{print $2}')
            PSET=$(echo "$LINE" | awk '{print $3}')
            echo "\"$NODE_NAME\",\"Backup\",\"$MC_NAME\",\"$DOMAIN\",\"$PSET\",\"$FILE_COUNT\"" >> "$OUTPUT_FILE"
        done < "$TEMP_DIR/node_backup_$NODE_NAME.txt"
    fi
    
    # Traitement des management classes d'archive
    if [ -s "$TEMP_DIR/node_archive_$NODE_NAME.txt" ]; then
        while IFS= read -r LINE; do
            MC_NAME=$(echo "$LINE" | awk '{print $1}')
            DOMAIN=$(echo "$LINE" | awk '{print $2}')
            PSET=$(echo "$LINE" | awk '{print $3}')
            echo "\"$NODE_NAME\",\"Archive\",\"$MC_NAME\",\"$DOMAIN\",\"$PSET\",\"$FILE_COUNT\"" >> "$OUTPUT_FILE"
        done < "$TEMP_DIR/node_archive_$NODE_NAME.txt"
    fi
    
done < "$TEMP_DIR/nodes.txt"

# -----------------------------------------------------------------------------
# 4. Générer un résumé
# -----------------------------------------------------------------------------
TOTAL_NODES=$(wc -l < "$TEMP_DIR/nodes.txt")
TOTAL_FILES=$(wc -l < "$TEMP_DIR/content.txt")

echo "========================================================================"
echo "RAPPORT COMPLET: $OUTPUT_FILE"
echo "========================================================================"
echo "Résumé:"
echo "  - Pool analysé: $POOL_NAME"
echo "  - Nombre total de nodes: $TOTAL_NODES"
echo "  - Nombre total de fichiers: $TOTAL_FILES"
echo "========================================================================"

# Affichage d'un aperçu du rapport
if [ -s "$OUTPUT_FILE" ]; then
    echo "Aperçu du rapport:"
    head -5 "$OUTPUT_FILE"
    echo "..."
    tail -5 "$OUTPUT_FILE"
fi

# -----------------------------------------------------------------------------
# Nettoyage et fin
# -----------------------------------------------------------------------------
cleanup
