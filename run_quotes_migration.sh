#!/bin/bash
cd "$(dirname "$0")"
echo "Running quotes migration..."
bundle exec rails db:migrate
echo "Migration complete!"
