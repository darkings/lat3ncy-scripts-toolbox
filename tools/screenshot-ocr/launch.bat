@echo off
setlocal
python "%~dp0screenshot_ocr.py"
exit /b %errorlevel%
