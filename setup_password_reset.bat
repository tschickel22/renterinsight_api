@echo off
REM Password Reset Setup and Test - Windows Batch

echo =========================================
echo Password Reset Feature Setup
echo =========================================
echo.

echo Step 1: Running database migration...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && bundle exec rails db:migrate"

if %errorlevel% neq 0 (
    echo Migration failed!
    pause
    exit /b 1
)

echo Migration completed successfully
echo.

echo Step 2: Running test suite...
wsl -d Ubuntu-24.04 bash -c "cd ~/src/renterinsight_api && ruby test_password_reset.rb"

echo.
echo =========================================
echo Setup Complete!
echo =========================================
echo.
echo Password reset feature is now active
echo.
echo Available Endpoints:
echo   POST /api/auth/request_password_reset
echo   POST /api/auth/verify_reset_token
echo   POST /api/auth/reset_password
echo.

pause
