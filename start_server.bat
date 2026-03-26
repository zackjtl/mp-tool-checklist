@echo off
echo Installing dependencies...
call npm.cmd install
if %ERRORLEVEL% neq 0 (
  echo Install failed!
  pause
  exit /b %ERRORLEVEL%
)
echo.
echo Starting server...
call npm.cmd start
pause
