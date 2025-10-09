#!/bin/bash
# Run this script in Ubuntu to migrate the database

cd ~/src/renterinsight_api
rails db:migrate

echo ""
echo "✅ Migration complete!"
echo ""
echo "Now restart your Rails server:"
echo "  rails s -b 0.0.0.0 -p 3001"
