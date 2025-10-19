#!/bin/bash

echo "=== Adding Resend Tracking to Quotes ==="
echo ""

cd /home/tschi/src/renterinsight_api

echo "Running migration..."
bundle exec rails db:migrate

echo ""
echo "Migration complete!"
echo ""
echo "New fields added to quotes table:"
echo "  - resend_count (integer, default: 0)"
echo "  - last_sent_at (datetime)"
echo ""
echo "Please restart your Rails server to use the new fields."
