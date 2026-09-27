@echo off
chcp 65001 >nul
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
  py -3 create-windows.py
) else (
  python create-windows.py
)
if errorlevel 1 (
  echo.
  echo 请从 https://www.python.org/downloads/windows/ 安装 Python 3.10+ 后重试。
  echo 需要包含 tkinter；不要下载仅供嵌入使用的 embeddable zip。
  pause
)
