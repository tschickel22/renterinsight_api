#!/bin/bash
# Fix duplicate migration error and run migrations

cd ~/src/renterinsight_api

# Remove the disabled migration file that's causing duplicate error
rm db/migrate/19691231170001_quickfix_tags_and_assignments.rb.disabled

# Now run the migrations
bundle exec rails db:migrate

echo ""
echo "✅ Migrations complete!"
echo ""
echo "Now restart your Rails server with Ctrl+C then:"
echo "  bin/rails s -b 0.0.0.0 -p 3001"
