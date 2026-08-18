#!/bin/bash

# Vérification de l'argument
if [ -z "$1" ]; then
    echo "Usage: $0 <nom_de_la_branche>"
    echo "Exemple: $0 19.0"
    exit 1
fi

TARGET_BRANCH="$1"
echo "=== Démarrage du basculement vers la branche : $TARGET_BRANCH ==="

# 1. Initialisation standard
git submodule init
git submodule update --recursive

# 2. Récupération de la liste des chemins des sous-modules
# L'option --recursive gère aussi les sous-modules de sous-modules
git submodule foreach --recursive 'echo $sm_path' | while read -r module_path; do
    
    echo ">> Traitement du module : $module_path"
    
    # On entre dans le dossier du module
    cd "$module_path" || continue

    # A. Essayer de changer de branche directement
    if git checkout "$TARGET_BRANCH" 2>/dev/null; then
        echo "   [OK] Basculé sur $TARGET_BRANCH"
    else
        # B. Si échec, on récupère la branche depuis le remote et on la crée
        echo "   [INFO] Branche non trouvée localement. Récupération..."
        
        if git fetch origin "$TARGET_BRANCH" 2>/dev/null; then
            if git checkout -b "$TARGET_BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null; then
                echo "   [OK] Branche créée depuis origin/$TARGET_BRANCH"
            else
                echo "   [ERREUR] Échec de la création de la branche locale."
            fi
        else
            echo "   [ERREUR] La branche '$TARGET_BRANCH' n'existe pas sur le dépôt distant (origin)."
        fi
    fi

    # C. Mise à jour (pull) si on est bien sur la branche cible
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" = "$TARGET_BRANCH" ]; then
        git pull origin "$TARGET_BRANCH" 2>/dev/null || echo "   [WARN] Pull échoué ou rien à mettre à jour."
    fi

    # On retourne à la racine du projet principal pour le prochain module
    cd - > /dev/null || exit
    echo ""
done

echo "=== Opération terminée ==="
git submodule status
