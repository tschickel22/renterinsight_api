# RenterInsight API (Rails)

Ruby/Rails API that powers the Renter Insight DMS/CRM platform.

- **Do not** commit `config/master.key`.
- Provide secrets via environment (e.g., `RAILS_MASTER_KEY`) in deploy environments.
- Default dev port: `3001`.

---

## Requirements

- Ruby 3.2.x
- Bundler
- System libs for native gems (SQLite/Postgres headers, build tools)

---

## Quick Start

```bash
bundle install
bin/rails s -p 3001
Common Tasks
See routes

bash
Copy code
bin/rails routes
DB schema dump

bash
Copy code
bin/rails db:schema:dump
Migration status

bash
Copy code
bin/rails db:migrate:status
Backup Tag (one-liner)
Use this anytime you want a dated snapshot tag in Git:

bash
Copy code
DATE_TAG="backup-$(date +%Y%m%d-%H%M%S)"
git tag -a "$DATE_TAG" -m "Backup snapshot $(date -Iseconds)"
git push origin "$DATE_TAG"
Snapshots (routes & schema)
If using a local script to capture API surface & DB state:

bash
Copy code
script/snapshot_audit.sh
git push
This generates:

docs/routes.full.txt

docs/routes.api_crm.txt

docs/schema.rb

docs/migrate.status.txt

docs/models.list.txt

CI (optional)
A minimal GitHub Actions workflow can install system deps, bundle, and print versions. Add .github/workflows/ci.yml with a simple smoke test if desired.
