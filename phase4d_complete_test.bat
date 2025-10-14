@echo off
REM Phase 4D Complete Test Suite (Windows)
REM Run this from Windows Command Prompt or PowerShell

echo ==========================================
echo Phase 4D: Communication Preferences
echo    Complete Test Suite
echo ==========================================
echo.

REM Check if we're in the Rails directory
if not exist "Gemfile" (
    echo ERROR: Not in Rails directory
    echo Please run this from: \\wsl.localhost\Ubuntu-24.04\home\tschi\src\renterinsight_api
    exit /b 1
)

echo Step 1: Running RSpec Tests
echo ==========================================
echo.

echo Running Model Specs...
wsl bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation --color

if %ERRORLEVEL% neq 0 (
    echo Model specs FAILED!
    exit /b 1
)

echo Model specs PASSED!
echo.

echo Running Controller Specs...
wsl bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation --color

if %ERRORLEVEL% neq 0 (
    echo Controller specs FAILED!
    exit /b 1
)

echo Controller specs PASSED!
echo.

echo ==========================================
echo Step 2: Creating Test Data
echo ==========================================
echo.

wsl ruby create_test_preferences.rb > phase4d_test_data.txt

if %ERRORLEVEL% neq 0 (
    echo Failed to create test data!
    exit /b 1
)

echo Test data created successfully!
echo.
echo Test credentials saved to: phase4d_test_data.txt
type phase4d_test_data.txt

echo.
echo ==========================================
echo Test Summary
echo ==========================================
echo.

echo All Tests PASSED!
echo.
echo Test Coverage:
echo    * Model specs: 30+ tests
echo    * Controller specs: 30+ tests
echo    * Total: 60+ tests
echo.
echo Features Verified:
echo    - Preference viewing (GET /api/portal/preferences)
echo    - Preference updates (PATCH /api/portal/preferences)
echo    - History tracking (GET /api/portal/preferences/history)
echo    - Security controls (cannot disable portal_enabled)
echo    - Boolean validation
echo    - JWT authentication
echo.
echo ==========================================
echo Phase 4D Implementation Complete!
echo ==========================================
echo.
echo Next steps:
echo 1. Start Rails server: wsl rails s -p 3001
echo 2. Use curl commands from phase4d_test_data.txt
echo 3. Test the API endpoints manually
echo.
echo For detailed API documentation, see:
echo   * PHASE4D_QUICK_REFERENCE.md
echo   * PHASE4D_COMPLETE_README.md
echo.
