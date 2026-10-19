@echo off
setlocal
cd /d "%~dp0"

:: Kiem tra quyen Administrator (de tranh loi Permission Denied tren o dia D:)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [VCAM] Dang yeu cau quyen Administrator de tranh loi Permission Denied...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Xoa file lock neu truoc do bi treo
if exist ".git\index.lock" del /f /q ".git\index.lock" 2>nul

if not exist ".git" (
    echo Initializing Git repository for the first time...
    git init
    if errorlevel 1 (
        echo git init failed.
        pause
        exit /b 1
    )
    git branch -M main
)

:: Luon dam bao remote origin la dung repo yeu cau
set "DEFAULT_REMOTE=https://github.com/codebywin/ios_vcam_roothide.git"
git remote get-url origin >nul 2>&1
if errorlevel 1 (
    git remote add origin "%DEFAULT_REMOTE%"
) else (
    git remote set-url origin "%DEFAULT_REMOTE%"
)

for /f "delims=" %%A in ('git config user.name 2^>nul') do set "GIT_NAME=%%A"
if not defined GIT_NAME (
    set /p "GIT_NAME=Your Git name: "
)
if not defined GIT_NAME (
    echo Git name cannot be empty.
    pause
    exit /b 1
)
git config user.name "%GIT_NAME%" 2>nul || git config --global user.name "%GIT_NAME%"

for /f "delims=" %%A in ('git config user.email 2^>nul') do set "GIT_EMAIL=%%A"
if not defined GIT_EMAIL (
    set /p "GIT_EMAIL=Your Git email: "
)
if not defined GIT_EMAIL (
    echo Git email cannot be empty.
    pause
    exit /b 1
)
git config user.email "%GIT_EMAIL%" 2>nul || git config --global user.email "%GIT_EMAIL%"

echo.
echo ========================================================
echo               VCAM AUTO COMMIT ^& PUSH
echo ========================================================
echo Remote URL: %DEFAULT_REMOTE%
echo.

:prompt_commit
set /p "MESSAGE=Nhap ten / noi dung Commit: "
if "%MESSAGE%"=="" (
    echo [!] Ten Commit khong duoc de trong. Vui long nhap lai!
    goto prompt_commit
)

echo.
set /p "TAG_NAME=Nhap Tag Release (Vi du: v1.0.0 hoac 1.0.0 - de trong neu khong tao tag): "

echo.
echo [1/3] git add .
if exist ".git\index.lock" del /f /q ".git\index.lock" 2>nul
git add .
if errorlevel 1 (
    echo git add failed.
    pause
    exit /b 1
)

git diff --cached --quiet
if not errorlevel 1 (
    echo [i] Khong co thay doi nao de commit tren nhanh.
    if not "%TAG_NAME%"=="" (
        goto push_tag_only
    )
    pause
    exit /b 0
)

echo.
echo [2/3] git commit
git commit -m "%MESSAGE%"
if errorlevel 1 (
    echo git commit failed.
    pause
    exit /b 1
)

echo.
echo [3/3] git push origin main
git push -u origin main
if errorlevel 1 (
    echo.
    echo [!] Push that bai, dang thu pull rebase truoc khi push...
    git pull --rebase origin main
    git push origin main
    if errorlevel 1 (
        echo [!] git push that bai. Vui long kiem tra token/quyen truy cap GitHub.
        pause
        exit /b 1
    )
)

:push_tag_only
if not "%TAG_NAME%"=="" (
    echo.
    echo [*] Dang tao va push Tag %TAG_NAME% len GitHub...
    git tag -a "%TAG_NAME%" -m "%MESSAGE%"
    git push origin "%TAG_NAME%"
    if errorlevel 1 (
        echo [!] Khong the push tag, nhung ma nguon da duoc push len nhanh main.
    ) else (
        echo [*] Da push Tag %TAG_NAME% thanh cong!
    )
)

echo.
echo ========================================================
echo              HOAN TAT THANH CONG!
echo ========================================================
pause
