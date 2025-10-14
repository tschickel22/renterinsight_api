#!/bin/bash
# Quick test to verify rate limiting works

echo "Testing rate limiting..."
echo ""

cd ~/src/renterinsight_api

# Test the specific failing spec
bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb:87 --format documentation

echo ""
echo "If this still fails, we need to check the Rails cache configuration in test environment"
