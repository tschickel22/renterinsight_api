#!/usr/bin/env bash
set -euo pipefail

bundle install --quiet

mkdir -p docs

# Routes
bin/rails routes > docs/routes.full.txt || true
bin/rails routes -g '^api_crm_' > docs/routes.api_crm.txt || true

# DB schema + migration status
bin/rails db:schema:dump 1>/dev/null || true
[ -f db/schema.rb ] && cp db/schema.rb docs/schema.rb || true
bin/rails db:migrate:status > docs/migrate.status.txt || true

# Models list
ls -1 app/models > docs/models.list.txt || true

git add docs/routes.full.txt docs/routes.api_crm.txt docs/schema.rb docs/migrate.status.txt docs/models.list.txt 2>/dev/null || true
git commit -m "chore(audit): snapshot routes + schema" || echo "(no changes to commit)"
