#!/bin/bash
# PHASE 4A - Quick Test Command
# Just paste this entire block into your WSL terminal

cd /home/tschi/src/renterinsight_api && \
echo "🚀 Running Phase 4A Tests..." && \
bundle install --quiet && \
RAILS_ENV=test bundle exec rails db:migrate && \
bundle exec rspec spec/lib/json_web_token_spec.rb spec/models/buyer_portal_access_spec.rb spec/controllers/api/portal/auth_controller_spec.rb --format documentation
