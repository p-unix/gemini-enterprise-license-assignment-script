# Developer notes

Two bash scripts that assign Gemini Enterprise licenses by edition using Google Group
membership as the source of truth, via the Discovery Engine v1 API.

- `gemini-license-sync.sh` — the sync (assign + optional reconcile/revoke). Flags:
  `--setup` (interactive wizard), `--dry-run`, `--no-input` (cron; never prompt).
  With no `config.json` in a TTY it auto-launches the wizard; the wizard is defined
  in `run_wizard` and populates the same globals the file loader (`load_config_file`)
  does, so both paths fall through to the shared bootstrap + main loop.
- `gemini-helpers.sh` — discovery/verification utilities (`check-prereqs`,
  `get-project-number`, `list-configs`, `list-licenses`).
- Config is `config.json` (see `config.json.example`); `project_id`/`project_number`
  auto-discover in Cloud Shell. A `group_mappings` value of `"auto"` resolves to the
  project's sole license config at startup (errors if multiple exist).

## Verified API facts (Discovery Engine v1)

Source of truth is the discovery doc: `https://discoveryengine.googleapis.com/$discovery/rest?version=v1`.

- Endpoint host is regional: `{ENDPOINT_LOCATION}-discoveryengine.googleapis.com` (use
  `global` for the global multi-region). User store is `default_user_store`.
- Location is a **multi-region** code, not a region. `global`/`us`/`eu` always work;
  additional multi-regions (e.g. `ca`, `au`) are whitelisted per project/customer.
  Region-level names like `northamerica-northeast1` are NOT valid (404). There is no
  `locations.list` method, so the valid set can't be enumerated via API — the wizard
  probes a common set (`global us eu ca au`) to auto-discover and always offers a manual
  entry for whitelisted regions it didn't probe. A project can hold configs in several
  multi-regions at once; each licenseConfig path embeds its own location. A sync run
  targets one location.
- Assign/revoke: `POST .../userStores/default_user_store:batchUpdateUserLicenses`.
  - `inlineSource.updateMask` is a **FieldMask string** (`"userPrincipal,licenseConfig"`),
    not an object — despite the licenses guide's curl example showing `{ "paths": [...] }`.
  - `deleteUnassignedUserLicenses` controls delete-vs-unassigned-state for users in the
    payload **that have no `licenseConfig`**. Removal is explicit: to revoke, send the user
    with `userPrincipal` only (no `licenseConfig`). The inline source is an upsert, NOT a
    full-replace — unlisted users are untouched.
- `licenseConfig` path: `projects/{PROJECT_NUMBER}/locations/{LOCATION}/licenseConfigs/{ID}`
  (project **number**, not ID).
- List assigned users: `GET .../userStores/default_user_store/userLicenses` — paginates via
  `nextPageToken`; supports `pageSize` (max 1000) and `filter=license_assignment_state = ASSIGNED`.
- List configs: `GET .../userStores/default_user_store/licenseConfigsUsageStats` — response
  top-level field is `licenseConfigUsageStats` (singular *Config*); each entry has
  `licenseConfig` and `usedLicenseCount`. Note this only surfaces configs that already have
  usage; the current docs recommend `billingAccounts/{ID}/billingAccountLicenseConfigs`
  (v1alpha) for full subscription discovery.

## Conventions

- Target bash 3.2+ (macOS) and Cloud Shell — no associative arrays. State is kept in temp
  files (`CURRENT_LICENSES_FILE` and `DESIRED_FILE`) of `userPrincipal<TAB>configId` and
  `configId<TAB>email` lines, diffed with `comm`/`awk` under strict `LC_ALL=C` collation.
- License assignment computes a delta via `comm -23` so only users lacking the target
  edition are sent to `batchUpdateUserLicenses`.
- Reconcile safety: users moving between editions (or present in any configured group) are
  cross-checked against all desired members and guarded from revocation.
- Runs under `set -euo pipefail`: never rely on `$?` after a bare `var=$(...)` assignment —
  branch on the command directly.
- Always support `--dry-run`.

## Future considerations

- Consider switching `list-configs` to `billingAccountLicenseConfigs` so zero-usage
  subscriptions are discoverable.
- No automated tests exist; the reconcile diff is verifiable standalone with `comm`/`awk`
  fixtures.
