#!/bin/bash
cd ~/src/renterinsight_api

echo "Running migrations..."
bundle exec rails db:migrate RAILS_ENV=test

echo ""
echo "Running tests..."
bundle exec rspec spec/services/buyer_portal_service_spec.rb --format documentation
