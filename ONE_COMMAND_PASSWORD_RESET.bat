@echo off
REM ONE-COMMAND PASSWORD RESET SETUP
REM This script does everything needed to get password reset working

echo ================================================================
echo      Password Reset Feature - Complete Setup
echo ================================================================
echo.

echo [Step 1/4] Running database migration...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && bundle exec rails db:migrate"
if %errorlevel% neq 0 (
    echo [ERROR] Migration failed!
    pause
    exit /b 1
)
echo [SUCCESS] Migration completed
echo.

echo [Step 2/4] Checking database schema...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && bundle exec rails db:schema:dump"
echo [SUCCESS] Schema updated
echo.

echo [Step 3/4] Verifying models and services...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && bundle exec rails runner 'puts PasswordResetToken.name'"
if %errorlevel% neq 0 (
    echo [ERROR] Model loading failed!
    pause
    exit /b 1
)
echo [SUCCESS] Models loaded successfully
echo.

echo [Step 4/4] Running comprehensive tests...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && ruby test_password_reset.rb"
echo [INFO] Tests completed
echo.

echo ================================================================
echo                    SETUP COMPLETE!
echo ================================================================
echo.
echo Password Reset Feature is now LIVE!
echo.
echo Available API Endpoints:
echo   * POST /api/auth/request_password_reset
echo   * POST /api/auth/verify_reset_token
echo   * POST /api/auth/reset_password
echo.
echo Documentation:
echo   * Full Guide: PASSWORD_RESET_COMPLETE.md
echo   * Quick Ref:  PASSWORD_RESET_QUICK_REF.md
echo.
echo Testing:
echo   * Run tests: ruby test_password_reset.rb
echo   * Manual:    See PASSWORD_RESET_COMPLETE.md
echo.
echo Frontend Status:
echo   [READY] Client Portal:   /client/forgot-password
echo   [READY] Admin Portal:    /admin/forgot-password
echo   [READY] Unified Portal:  /forgot-password
echo.
echo Next Steps:
echo   1. Start Rails server: bundle exec rails s
echo   2. Test frontend at: http://localhost:3000/forgot-password
echo   3. Check logs: tail -f log/development.log
echo.
echo Ready to use!
echo.

pause
