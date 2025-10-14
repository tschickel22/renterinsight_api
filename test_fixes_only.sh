#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Quick Fix Test ==="
echo "Testing BuyerPortalService + Controllers"
echo ""

bundle exec rspec \
  spec/services/buyer_portal_service_spec.rb \
  spec/controllers/api/portal/auth_controller_spec.rb \
  spec/controllers/api/portal/communications_controller_spec.rb \
  --format progress

echo ""
echo "Done!"
