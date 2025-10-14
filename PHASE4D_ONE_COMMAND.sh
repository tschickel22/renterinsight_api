#!/bin/bash
# Phase 4D - One Command Setup & Test

echo "╔════════════════════════════════════════╗"
echo "║  Phase 4D - One Command Deployment    ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Make scripts executable
chmod +x run_phase4d_tests.sh
chmod +x verify_phase4d.sh

echo "Step 1: Verifying installation..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./verify_phase4d.sh

echo ""
echo "Step 2: Running all tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./run_phase4d_tests.sh

echo ""
echo "Step 3: Creating test data..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ruby create_test_preferences.rb

echo ""
echo "╔════════════════════════════════════════╗"
echo "║       Phase 4D Setup Complete! ✅      ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "🎉 You can now:"
echo ""
echo "  1. Start the server:"
echo "     rails s -p 3001"
echo ""
echo "  2. Test endpoints with the curl commands above"
echo ""
echo "  3. View documentation:"
echo "     cat PHASE4D_COMPLETE.md"
echo ""
echo "  4. Check success summary:"
echo "     cat PHASE4D_SUCCESS.md"
echo ""
