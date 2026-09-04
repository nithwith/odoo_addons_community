# odoo_addons_community

Selected OCA addons for Odoo 19.0.

## OCA addons synchronization

The upstream OCA repositories are Git submodules stored under `.oca/`. The
actual Odoo addons are generated as regular directories at this repository's
root, so an Odoo instance only needs the root in its `addons_path`.

Initialize a fresh checkout with:

```bash
git submodule update --init
./oca_sync.sh
```

Update all OCA repositories and regenerate the root addons with:

```bash
./oca_sync.sh
git status
git add .
git commit -m "Update OCA addons"
```

To migrate every OCA repository to another branch, for example 19.0, run:

```bash
./oca_sync.sh --branch 19.0
```

The script checks that the requested branch exists in every upstream
repository before switching the submodules. It also refuses dirty submodules,
duplicate addon names, and collisions with unmanaged root directories.

Do not edit generated root addons directly. `.oca-modules` records each
generated addon, its source repository, source commit, and branch. The script
uses that file as the exclusive allow-list of root directories it may replace
or remove.

## Add OCA repo

```bash
git submodule add -b 19.0 git@github.com:OCA/NOM_DU_REPO.git .oca/NOM_DU_REPO
./oca_sync.sh
```

