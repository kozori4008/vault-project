@echo off
pushd "%~dp0out"
myapp.exe %* > "%~dp0\run.out" 2> "%~dp0\run.err"
set rc=%ERRORLEVEL%
popd
exit /b %rc%
