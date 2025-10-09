@echo off
echo =====================================
echo Running Lead Activities Migration
echo =====================================
echo.

cd /d "%~dp0"
echo Current directory: %CD%
echo.

echo Running migration...
wsl bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rails db:migrate"

if %ERRORLEVEL% EQU 0 (
    echo.
    echo Migration completed successfully!
    echo.
    
    echo Verifying table...
    wsl bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rails runner \"if ActiveRecord::Base.connection.table_exists?('lead_activities'); puts 'Table exists!'; else puts 'Table NOT found'; end\""
) else (
    echo.
    echo Migration failed!
    echo Please check the error messages above
)

echo.
echo =====================================
echo IMPORTANT: Restart your Rails server!
echo =====================================
echo.
pause
