#!/bin/bash

echo "🔧 Applying Phase 4E Test Fixes..."
echo "=================================================="

# Copy the fixed service spec
echo "✅ Copying fixed buyer_portal_service_spec.rb..."
cp spec/services/buyer_portal_service_spec_FIXED.rb spec/services/buyer_portal_service_spec.rb

echo ""
echo "=================================================="
echo "✅ Service spec fixed!"
echo ""
echo "Now we need to fix the other test files."
echo "Let me check if you want me to continue with the remaining fixes..."
