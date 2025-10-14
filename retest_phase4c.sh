#!/bin/bash
# Quick fix and retest for Phase 4C

echo "🔧 Running Phase 4C tests..."
cd ~/src/renterinsight_api

echo ""
echo "📝 Running RSpec tests..."
bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb spec/models/portal_document_spec.rb --format documentation

echo ""
echo "✅ Test run complete!"
