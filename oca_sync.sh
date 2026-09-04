#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BRANCH="19.0"
branch="$DEFAULT_BRANCH"

usage() {
    cat <<'EOF'
Usage: ./oca_sync.sh [--branch BRANCH]

Update the OCA submodules and regenerate the Odoo addons at the repository root.

Options:
  --branch BRANCH  Use BRANCH for every OCA repository (default: 19.0).
  -h, --help       Show this help message.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --branch)
            (($# >= 2)) || die "--branch requires a value"
            branch="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

for command_name in git rsync mktemp sort; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command not found: $command_name"
done

git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || die "invalid Git branch name: $branch"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
    || die "oca_sync.sh must be run from a Git working tree"
repo_root="$(cd -- "$repo_root" && pwd -P)"

[[ "$script_dir" == "$repo_root" ]] \
    || die "oca_sync.sh must be located at the repository root"
[[ -f "$repo_root/.gitmodules" ]] || die ".gitmodules not found"

cd -- "$repo_root"

declare -a submodule_names=()
declare -a repo_names=()
declare -a repo_paths=()
declare -a old_commits=()
declare -a new_commits=()
declare -A seen_repo_paths=()

while IFS= read -r -d '' config_entry; do
    config_key="${config_entry%%$'\n'*}"
    repo_path="${config_entry#*$'\n'}"
    submodule_name="${config_key#submodule.}"
    submodule_name="${submodule_name%.path}"

    if [[ ! "$repo_path" =~ ^\.oca/([A-Za-z0-9._-]+)$ ]]; then
        die "submodule \"$submodule_name\" must use a direct child of .oca/ (found: $repo_path)"
    fi
    repo_name="${BASH_REMATCH[1]}"
    [[ -z "${seen_repo_paths[$repo_path]:-}" ]] \
        || die "duplicate submodule path in .gitmodules: $repo_path"

    seen_repo_paths["$repo_path"]=1
    submodule_names+=("$submodule_name")
    repo_names+=("$repo_name")
    repo_paths+=("$repo_path")
done < <(git config -z -f .gitmodules --get-regexp '^submodule\..*\.path$')

((${#repo_paths[@]} > 0)) || die "no OCA submodules found in .gitmodules"

printf '[OCA] Branch: %s\n\n' "$branch"

# Refuse dirty initialized worktrees before Git is allowed to update anything.
for repo_path in "${repo_paths[@]}"; do
    if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        dirty_output="$(git -C "$repo_path" status --porcelain --untracked-files=all)"
        if [[ -n "$dirty_output" ]]; then
            printf 'ERROR: dirty OCA repository: %s\n\n%s\n' \
                "$repo_path" "$dirty_output" >&2
            die "commit, stash, or discard these changes before synchronizing"
        fi
    fi
done

# Sync URLs first so initialization uses the current .gitmodules configuration.
git submodule sync --recursive >/dev/null
git submodule update --init -- "${repo_paths[@]}"

for repo_path in "${repo_paths[@]}"; do
    git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "submodule could not be initialized: $repo_path"

    dirty_output="$(git -C "$repo_path" status --porcelain --untracked-files=all)"
    if [[ -n "$dirty_output" ]]; then
        printf 'ERROR: dirty OCA repository: %s\n\n%s\n' \
            "$repo_path" "$dirty_output" >&2
        die "commit, stash, or discard these changes before synchronizing"
    fi
done

declare -a fetch_failures=()
declare -a missing_branches=()
declare -a unpublished_commits=()

# Fetch and validate every repository before changing any submodule worktree.
for index in "${!repo_paths[@]}"; do
    repo_path="${repo_paths[$index]}"
    repo_name="${repo_names[$index]}"
    old_commit="$(git -C "$repo_path" rev-parse HEAD)"
    old_commits+=("$old_commit")

    printf '[FETCH] %s\n' "$repo_name"
    if ! git -C "$repo_path" fetch --prune --quiet origin; then
        fetch_failures+=("$repo_name")
        continue
    fi

    if ! git -C "$repo_path" show-ref --verify --quiet \
        "refs/remotes/origin/$branch"; then
        missing_branches+=("$repo_name")
        continue
    fi

    remote_refs_containing_head="$(
        git -C "$repo_path" for-each-ref \
            --format='%(refname)' --contains "$old_commit" refs/remotes/origin/
    )"
    if [[ -z "$remote_refs_containing_head" ]]; then
        unpublished_commits+=("$repo_name:$old_commit")
    fi

    # checkout -B resets an existing local target branch even when it is not
    # currently checked out. Protect an unpublished tip there as well.
    if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
        local_branch_commit="$(git -C "$repo_path" rev-parse "refs/heads/$branch")"
        if [[ "$local_branch_commit" != "$old_commit" ]]; then
            remote_refs_containing_local_branch="$(
                git -C "$repo_path" for-each-ref \
                    --format='%(refname)' --contains "$local_branch_commit" \
                    refs/remotes/origin/
            )"
            if [[ -z "$remote_refs_containing_local_branch" ]]; then
                unpublished_commits+=("$repo_name:$local_branch_commit")
            fi
        fi
    fi
done

if ((${#fetch_failures[@]} > 0)); then
    printf '\nERROR: could not fetch the following OCA repositories:\n' >&2
    printf '  %s\n' "${fetch_failures[@]}" >&2
fi
if ((${#missing_branches[@]} > 0)); then
    printf '\nERROR: branch \"%s\" does not exist in:\n' "$branch" >&2
    printf '  %s\n' "${missing_branches[@]}" >&2
fi
if ((${#unpublished_commits[@]} > 0)); then
    printf '\nERROR: current commits are not reachable from any origin ref:\n' >&2
    for unpublished in "${unpublished_commits[@]}"; do
        printf '  %s (%s)\n' "${unpublished%%:*}" "${unpublished#*:}" >&2
    done
    printf 'Refusing to make these commits unreachable.\n' >&2
fi
if ((${#fetch_failures[@]} + ${#missing_branches[@]} + ${#unpublished_commits[@]} > 0)); then
    exit 1
fi

# Keep the declared tracking branch consistent only after every remote passed.
for index in "${!submodule_names[@]}"; do
    git config -f .gitmodules \
        "submodule.${submodule_names[$index]}.branch" "$branch"
done
git submodule sync --recursive >/dev/null

for index in "${!repo_paths[@]}"; do
    repo_path="${repo_paths[$index]}"
    repo_name="${repo_names[$index]}"
    old_commit="${old_commits[$index]}"

    git -C "$repo_path" checkout --quiet -B "$branch" \
        "refs/remotes/origin/$branch"
    git -C "$repo_path" reset --hard --quiet \
        "refs/remotes/origin/$branch"
    new_commit="$(git -C "$repo_path" rev-parse HEAD)"
    new_commits+=("$new_commit")

    printf '\n[UPDATE] %s\n' "$repo_name"
    printf '         %.8s -> %.8s\n' "$old_commit" "$new_commit"
done

declare -A old_managed=()
declare -a old_addons=()

if [[ -e .oca-modules || -L .oca-modules ]]; then
    [[ -f .oca-modules && ! -L .oca-modules ]] \
        || die ".oca-modules must be a regular file"

    metadata_line_number=0
    while IFS= read -r metadata_line || [[ -n "$metadata_line" ]]; do
        ((metadata_line_number += 1))
        [[ -n "$metadata_line" ]] || continue

        if [[ ! "$metadata_line" =~ ^([A-Za-z0-9_]+)\|([A-Za-z0-9._-]+)\|([0-9a-f]{40})\|([^\|[:space:]]+)$ ]]; then
            die "invalid .oca-modules entry on line $metadata_line_number"
        fi

        old_addon="${BASH_REMATCH[1]}"
        [[ -z "${old_managed[$old_addon]:-}" ]] \
            || die "duplicate addon in .oca-modules: $old_addon"
        old_managed["$old_addon"]=1
        old_addons+=("$old_addon")
    done < .oca-modules
fi

declare -A addon_source_paths=()
declare -A addon_repo_names=()
declare -A addon_repo_commits=()
declare -A addon_all_sources=()
declare -A duplicate_addons=()

for index in "${!repo_paths[@]}"; do
    repo_path="${repo_paths[$index]}"
    repo_name="${repo_names[$index]}"
    repo_commit="${new_commits[$index]}"

    while IFS= read -r -d '' manifest_path; do
        addon_path="${manifest_path%/__manifest__.py}"
        addon_name="${addon_path##*/}"
        [[ "$addon_name" =~ ^[A-Za-z0-9_]+$ ]] \
            || die "invalid Odoo addon directory name: $addon_path"

        if [[ -n "${addon_source_paths[$addon_name]:-}" ]]; then
            duplicate_addons["$addon_name"]=1
            addon_all_sources["$addon_name"]+=$'\n'"$addon_path"
        else
            addon_source_paths["$addon_name"]="$addon_path"
            addon_repo_names["$addon_name"]="$repo_name"
            addon_repo_commits["$addon_name"]="$repo_commit"
            addon_all_sources["$addon_name"]="$addon_path"
        fi
    done < <(
        find "$repo_path" -mindepth 2 -maxdepth 2 -type f \
            -name __manifest__.py -print0
    )
done

if ((${#duplicate_addons[@]} > 0)); then
    mapfile -t duplicate_names < <(
        printf '%s\n' "${!duplicate_addons[@]}" | LC_ALL=C sort
    )
    for addon_name in "${duplicate_names[@]}"; do
        printf '\nERROR: duplicate addon "%s"\n\nFound in:\n' "$addon_name" >&2
        while IFS= read -r source_path; do
            printf '  %s\n' "$source_path" >&2
        done <<< "${addon_all_sources[$addon_name]}"
    done
    exit 1
fi

declare -a addon_names=()
if ((${#addon_source_paths[@]} > 0)); then
    mapfile -t addon_names < <(
        printf '%s\n' "${!addon_source_paths[@]}" | LC_ALL=C sort
    )
fi

# A root path is replaceable only when the previous metadata explicitly owns it.
declare -a root_collisions=()
for addon_name in "${addon_names[@]}"; do
    if [[ -e "$repo_root/$addon_name" || -L "$repo_root/$addon_name" ]]; then
        if [[ -z "${old_managed[$addon_name]:-}" ]]; then
            root_collisions+=("$addon_name")
        fi
    fi
done

if ((${#root_collisions[@]} > 0)); then
    for addon_name in "${root_collisions[@]}"; do
        printf '\nERROR: OCA addon "%s" collides with an unmanaged root path:\n' \
            "$addon_name" >&2
        printf '  source: %s\n  root:   %s\n' \
            "${addon_source_paths[$addon_name]}" "$repo_root/$addon_name" >&2
    done
    printf '\nNo root addon was modified.\n' >&2
    exit 1
fi

stage_dir=""
backup_dir=""
transaction_started=0
transaction_complete=0
metadata_backed_up=0
metadata_installed=0
declare -a backed_up_addons=()
declare -a installed_addons=()

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM

    if ((transaction_started == 1 && transaction_complete == 0)); then
        set +e
        printf '\n[ROLLBACK] Restoring the previous generated addons.\n' >&2
        rollback_failed=0

        if ((metadata_installed == 1)) \
            && [[ -e "$repo_root/.oca-modules" ]]; then
            mv -T -- "$repo_root/.oca-modules" "$stage_dir/.oca-modules.failed" \
                || rollback_failed=1
        fi
        if ((metadata_backed_up == 1)) \
            && [[ -e "$backup_dir/.oca-modules" ]]; then
            mv -T -- "$backup_dir/.oca-modules" "$repo_root/.oca-modules" \
                || rollback_failed=1
        fi

        for ((rollback_index=${#installed_addons[@]} - 1; rollback_index >= 0; rollback_index--)); do
            addon_name="${installed_addons[$rollback_index]}"
            if [[ -e "$repo_root/$addon_name" || -L "$repo_root/$addon_name" ]]; then
                mv -T -- "$repo_root/$addon_name" \
                    "$stage_dir/addons/$addon_name" || rollback_failed=1
            fi
        done
        for ((rollback_index=${#backed_up_addons[@]} - 1; rollback_index >= 0; rollback_index--)); do
            addon_name="${backed_up_addons[$rollback_index]}"
            if [[ -e "$backup_dir/addons/$addon_name" \
                || -L "$backup_dir/addons/$addon_name" ]]; then
                mv -T -- "$backup_dir/addons/$addon_name" \
                    "$repo_root/$addon_name" || rollback_failed=1
            fi
        done

        if ((rollback_failed == 1)); then
            printf 'ERROR: rollback was incomplete; recovery data was preserved in:\n' >&2
            printf '  %s\n  %s\n' "$stage_dir" "$backup_dir" >&2
            exit_status=1
            stage_dir=""
            backup_dir=""
        fi
    fi

    [[ -z "$stage_dir" || ! -d "$stage_dir" ]] \
        || rm -rf -- "$stage_dir"
    [[ -z "$backup_dir" || ! -d "$backup_dir" ]] \
        || rm -rf -- "$backup_dir"
    exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_dir="$(mktemp -d "$repo_root/.oca-sync-stage.XXXXXX")"
backup_dir="$(mktemp -d "$repo_root/.oca-sync-backup.XXXXXX")"
mkdir -p -- "$stage_dir/addons" "$backup_dir/addons"

for addon_name in "${addon_names[@]}"; do
    mkdir -- "$stage_dir/addons/$addon_name"
    rsync --archive --delete --exclude=.git -- \
        "${addon_source_paths[$addon_name]}/" \
        "$stage_dir/addons/$addon_name/"
done

metadata_stage="$stage_dir/.oca-modules"
: > "$metadata_stage"
for addon_name in "${addon_names[@]}"; do
    printf '%s|%s|%s|%s\n' \
        "$addon_name" \
        "${addon_repo_names[$addon_name]}" \
        "${addon_repo_commits[$addon_name]}" \
        "$branch" >> "$metadata_stage"
done

# The root mutation is transactional: old content is retained until success.
transaction_started=1
if [[ -e "$repo_root/.oca-modules" ]]; then
    mv -T -- "$repo_root/.oca-modules" "$backup_dir/.oca-modules"
    metadata_backed_up=1
fi

for addon_name in "${old_addons[@]}"; do
    if [[ -e "$repo_root/$addon_name" || -L "$repo_root/$addon_name" ]]; then
        mv -T -- "$repo_root/$addon_name" "$backup_dir/addons/$addon_name"
        backed_up_addons+=("$addon_name")
    fi
done

for addon_name in "${addon_names[@]}"; do
    if [[ -e "$repo_root/$addon_name" || -L "$repo_root/$addon_name" ]]; then
        die "root path appeared during synchronization: $addon_name"
    fi
    mv -T -- "$stage_dir/addons/$addon_name" "$repo_root/$addon_name"
    installed_addons+=("$addon_name")
done

mv -T -- "$metadata_stage" "$repo_root/.oca-modules"
metadata_installed=1
transaction_complete=1

for addon_name in "${addon_names[@]}"; do
    printf '[SYNC] %s <- %s\n' \
        "$addon_name" "${addon_repo_names[$addon_name]}"
done

if ((${#old_addons[@]} > 0)); then
    mapfile -t sorted_old_addons < <(
        printf '%s\n' "${old_addons[@]}" | LC_ALL=C sort
    )
    for addon_name in "${sorted_old_addons[@]}"; do
        if [[ -z "${addon_source_paths[$addon_name]:-}" ]]; then
            printf '[REMOVE] %s\n' "$addon_name"
        fi
    done
fi

printf '\nDone.\nRepositories: %d\nAddons: %d\n' \
    "${#repo_paths[@]}" "${#addon_names[@]}"

if [[ -n "$(git status --porcelain)" ]]; then
    printf '\nThe main repository contains changes. Review them with:\n  git status\n'
fi
