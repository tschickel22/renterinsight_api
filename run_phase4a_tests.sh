#!/bin/bash
# Fixed test command for Phase 4A

cd /home/tschi/src/renterinsight_api

echo "🚀 Running Phase 4A Tests (SQLite compatible)..."
echo ""

# Run migrations
echo "📦 Running migrations..."
RAILS_ENV=test bundle exec rails db:migrate

echo ""
echo "🧪 Running tests..."
bundle exec rspec spec/lib/json_web_token_spec.rb \
  spec/models/buyer_portal_access_spec.rb \
  spec/controllers/api/portal/auth_controller_spec.rb \
  --format documentation

echo ""
echo "✅ Tests complete!"
