# Generate self-signed certificates for testing
# This script creates certificates for local development and testing

param(
    [string]$CertDir = "certs",
    [string]$KeyFile = "server.key",
    [string]$CertFile = "server.crt"
)

Write-Host "🔐 Generating self-signed certificates for HTTPS load balancer..." -ForegroundColor Green

# Create certs directory if it doesn't exist
if (!(Test-Path $CertDir)) {
    New-Item -ItemType Directory -Path $CertDir | Out-Null
}

$KeyPath = Join-Path $CertDir $KeyFile
$CertPath = Join-Path $CertDir $CertFile

# Generate private key
Write-Host "Generating private key..." -ForegroundColor Yellow
openssl genrsa -out $KeyPath 2048

# Generate certificate signing request
Write-Host "Generating certificate signing request..." -ForegroundColor Yellow
openssl req -new -key $KeyPath -out "$CertDir\server.csr" -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

# Generate self-signed certificate
Write-Host "Generating self-signed certificate..." -ForegroundColor Yellow
openssl x509 -req -days 365 -in "$CertDir\server.csr" -signkey $KeyPath -out $CertPath

# Clean up CSR file
Remove-Item "$CertDir\server.csr" -ErrorAction SilentlyContinue

Write-Host "✅ Certificates generated successfully!" -ForegroundColor Green
Write-Host "📁 Certificate files:" -ForegroundColor Cyan
Write-Host "   - Private key: $KeyPath" -ForegroundColor White
Write-Host "   - Certificate: $CertPath" -ForegroundColor White
Write-Host ""
Write-Host "⚠️  Note: These are self-signed certificates for testing only." -ForegroundColor Yellow
Write-Host "   For production, use certificates from a trusted CA." -ForegroundColor Yellow
Write-Host ""
Write-Host "🚀 You can now start the load balancer with HTTPS enabled." -ForegroundColor Green 