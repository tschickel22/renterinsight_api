@echo off
echo ========================================
echo Quotes Module Backend Setup
echo ========================================
echo.

cd /d %~dp0

echo Running database migration...
call bundle exec rails db:migrate

if %ERRORLEVEL% EQU 0 (
    echo Migration completed successfully!
) else (
    echo Migration failed. Please check the error above.
    pause
    exit /b 1
)

echo.
echo Verifying routes...
call bundle exec rails routes | findstr quotes

echo.
echo ========================================
echo Setup Complete!
echo ========================================
echo.
echo Documentation: See QUOTES_BACKEND_IMPLEMENTATION.md
echo API is ready at: http://localhost:3001/api/v1/quotes
echo.
pause
