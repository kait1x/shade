@echo off
REM Generate self-signed TLS certificates for development.
REM For production, use Let's Encrypt / certbot instead.
REM
REM Usage: gen-certs.bat [hostname]
REM   hostname defaults to localhost

set HOSTNAME=%1
if "%HOSTNAME%"=="" set HOSTNAME=localhost

set CERT_DIR=%~dp0certs

if not exist "%CERT_DIR%" mkdir "%CERT_DIR%"

openssl req -x509 -nodes -days 365 ^
  -newkey rsa:2048 ^
  -keyout "%CERT_DIR%\key.pem" ^
  -out "%CERT_DIR%\cert.pem" ^
  -subj "/CN=%HOSTNAME%" ^
  -addext "subjectAltName=DNS:%HOSTNAME%,DNS:localhost,IP:127.0.0.1,IP:10.0.2.2"

echo.
echo [ok] Certificates generated in %CERT_DIR%
echo   cert.pem - server certificate
echo   key.pem  - private key
echo.
echo WARNING: Self-signed cert. Clients must pin or accept warning.
