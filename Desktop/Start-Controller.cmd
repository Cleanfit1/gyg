@echo off
setlocal
set "PYTHONDONTWRITEBYTECODE=1"
if exist "D:\Python312\pythonw.exe" (
  start "" "D:\Python312\pythonw.exe" "%~dp0controller.py"
) else (
  py -3 -B "%~dp0controller.py"
)
endlocal
