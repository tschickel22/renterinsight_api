@echo off
REM Phase 4D - One Command Test Runner for Windows
REM Run this from Windows Command Prompt to test Phase 4D

echo ==================================================
echo   Phase 4D: Communication Preferences
echo   Complete Test Suite
echo ==================================================
echo.

echo Step 1: Running Controller Tests...
echo -----------------------------------
wsl -d Ubuntu-24.04 -e bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation --color"

echo.
echo Step 2: Running Model Tests...
echo -----------------------------------
wsl -d Ubuntu-24.04 -e bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation --color"

echo.
echo ==================================================
echo Test Summary
echo ==================================================
wsl -d Ubuntu-24.04 -e bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb spec/models/buyer_portal_access_preferences_spec.rb --format progress --color"

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ==================================================
    echo ✅ ALL TESTS PASSED!
    echo ==================================================
    echo.
    echo Phase 4D Implementation Status:
    echo   ✅ Controller ^(30+ tests^)
    echo   ✅ Model ^(30+ tests^)
    echo   ✅ Change tracking
    echo   ✅ Security validation
    echo   ✅ History tracking
    echo.
    echo Next step: Run 'ruby create_test_preferences.rb' for test data
    echo ==================================================
) else (
    echo.
    echo ⚠️  Some tests failed. Review output above.
    exit /b 1
)
