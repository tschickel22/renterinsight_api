@echo off
REM Phase 4D - One Command Setup & Test (Windows)

echo ╔════════════════════════════════════════╗
echo ║  Phase 4D - One Command Deployment    ║
echo ╚════════════════════════════════════════╝
echo.

echo Step 1: Running all tests...
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb spec/models/buyer_portal_access_preferences_spec.rb --format documentation

echo.
echo Step 2: Creating test data...
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ruby create_test_preferences.rb

echo.
echo ╔════════════════════════════════════════╗
echo ║       Phase 4D Setup Complete! ✅      ║
echo ╚════════════════════════════════════════╝
echo.
echo 🎉 You can now:
echo.
echo   1. Start the server:
echo      rails s -p 3001
echo.
echo   2. Test endpoints with the curl commands above
echo.
echo   3. View documentation:
echo      type PHASE4D_COMPLETE.md
echo.
echo   4. Check success summary:
echo      type PHASE4D_SUCCESS.md
echo.
pause
