#!/bin/bash
cd "$(dirname "$0")"
echo "Running migration for lead_activities..."
bundle exec rails db:migrate VERSION=20251008000001
echo "Migration complete!"
echo ""
echo "Current schema version:"
bundle exec rails db:version
