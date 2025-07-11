# deployment script for the production https load balancer
# this script handles the complete deployment process

param(
    [string]$Environment = "development",
    [string]$ConfigFile = "config.toml",
    [switch]$GenerateCerts,
    [switch]$BuildDocker,
    [switch]$DeployDocker,
    [switch]$DeployKubernetes,
    [switch]$SkipTests
)

Write-Host "🚀 starting load balancer deployment..." -ForegroundColor Green

# colors for output
$colors = @{
    success = "Green"
    error = "Red"
    warning = "Yellow"
    info = "Cyan"
}

function Write-Status {
    param([string]$Message, [string]$Status = "info")
    Write-Host $Message -ForegroundColor $colors[$Status]
}

function Test-Prerequisites {
    Write-Status "checking prerequisites..." "info"
    
    $prerequisites = @{
        "rust" = $false
        "cargo" = $false
        "docker" = $false
        "docker-compose" = $false
        "openssl" = $false
    }
    
    # check rust
    try {
        $rustVersion = rustc --version 2>$null
        if ($rustVersion) {
            $prerequisites.rust = $true
            Write-Status "  ✅ rust installed" "success"
        }
    } catch {
        Write-Status "  ❌ rust not found" "error"
    }
    
    # check cargo
    try {
        $cargoVersion = cargo --version 2>$null
        if ($cargoVersion) {
            $prerequisites.cargo = $true
            Write-Status "  ✅ cargo installed" "success"
        }
    } catch {
        Write-Status "  ❌ cargo not found" "error"
    }
    
    # check docker
    try {
        $dockerVersion = docker --version 2>$null
        if ($dockerVersion) {
            $prerequisites.docker = $true
            Write-Status "  ✅ docker installed" "success"
        }
    } catch {
        Write-Status "  ❌ docker not found" "error"
    }
    
    # check docker-compose
    try {
        $dockerComposeVersion = docker-compose --version 2>$null
        if ($dockerComposeVersion) {
            $prerequisites.docker_compose = $true
            Write-Status "  ✅ docker-compose installed" "success"
        }
    } catch {
        Write-Status "  ❌ docker-compose not found" "error"
    }
    
    # check openssl
    try {
        $opensslVersion = openssl version 2>$null
        if ($opensslVersion) {
            $prerequisites.openssl = $true
            Write-Status "  ✅ openssl installed" "success"
        }
    } catch {
        Write-Status "  ❌ openssl not found" "error"
    }
    
    $allInstalled = $prerequisites.Values -notcontains $false
    
    if ($allInstalled) {
        Write-Status "✅ all prerequisites met" "success"
        return $true
    } else {
        Write-Status "❌ some prerequisites missing" "error"
        return $false
    }
}

function Generate-Certificates {
    Write-Status "generating certificates..." "info"
    
    if (!(Test-Path "certs")) {
        New-Item -ItemType Directory -Path "certs" | Out-Null
    }
    
    $certScript = "scripts/generate-certs.ps1"
    if (Test-Path $certScript) {
        try {
            & $certScript
            Write-Status "✅ certificates generated successfully" "success"
            return $true
        } catch {
            Write-Status "❌ certificate generation failed: $($_.Exception.Message)" "error"
            return $false
        }
    } else {
        Write-Status "❌ certificate generation script not found" "error"
        return $false
    }
}

function Build-Application {
    Write-Status "building application..." "info"
    
    try {
        # clean previous build
        if (Test-Path "target") {
            Write-Status "  cleaning previous build..." "info"
            cargo clean
        }
        
        # build in release mode
        Write-Status "  building in release mode..." "info"
        cargo build --release
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "✅ application built successfully" "success"
            return $true
        } else {
            Write-Status "❌ build failed" "error"
            return $false
        }
    } catch {
        Write-Status "❌ build failed: $($_.Exception.Message)" "error"
        return $false
    }
}

function Build-DockerImage {
    Write-Status "building docker image..." "info"
    
    try {
        docker build -t rust-load-balancer:latest .
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "✅ docker image built successfully" "success"
            return $true
        } else {
            Write-Status "❌ docker build failed" "error"
            return $false
        }
    } catch {
        Write-Status "❌ docker build failed: $($_.Exception.Message)" "error"
        return $false
    }
}

function Deploy-Docker {
    Write-Status "deploying with docker-compose..." "info"
    
    try {
        # stop existing containers
        Write-Status "  stopping existing containers..." "info"
        docker-compose down
        
        # start services
        Write-Status "  starting services..." "info"
        docker-compose up -d
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "✅ docker deployment successful" "success"
            return $true
        } else {
            Write-Status "❌ docker deployment failed" "error"
            return $false
        }
    } catch {
        Write-Status "❌ docker deployment failed: $($_.Exception.Message)" "error"
        return $false
    }
}

function Deploy-Kubernetes {
    Write-Status "deploying to kubernetes..." "info"
    
    try {
        # check if kubectl is available
        $kubectlVersion = kubectl version --client 2>$null
        if (!$kubectlVersion) {
            Write-Status "❌ kubectl not found" "error"
            return $false
        }
        
        # create namespace if it doesn't exist
        Write-Status "  creating namespace..." "info"
        kubectl create namespace load-balancer --dry-run=client -o yaml | kubectl apply -f -
        
        # apply kubernetes manifests
        Write-Status "  applying kubernetes manifests..." "info"
        kubectl apply -f k8s/ -n load-balancer
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "✅ kubernetes deployment successful" "success"
            return $true
        } else {
            Write-Status "❌ kubernetes deployment failed" "error"
            return $false
        }
    } catch {
        Write-Status "❌ kubernetes deployment failed: $($_.Exception.Message)" "error"
        return $false
    }
}

function Test-Deployment {
    Write-Status "testing deployment..." "info"
    
    $testScript = "scripts/test-load-balancer.ps1"
    if (Test-Path $testScript) {
        try {
            & $testScript -LoadBalancerUrl "https://localhost:443" -TestDuration 30 -ConcurrentUsers 5
            return $true
        } catch {
            Write-Status "❌ deployment test failed: $($_.Exception.Message)" "error"
            return $false
        }
    } else {
        Write-Status "⚠️ test script not found, skipping tests" "warning"
        return $true
    }
}

function Show-Status {
    Write-Status "checking deployment status..." "info"
    
    try {
        # check if load balancer is running
        $loadBalancerStatus = docker-compose ps load-balancer 2>$null
        if ($loadBalancerStatus -match "Up") {
            Write-Status "✅ load balancer is running" "success"
        } else {
            Write-Status "❌ load balancer is not running" "error"
        }
        
        # check backend services
        $backendServices = @("backend-1", "backend-2", "backend-3")
        foreach ($service in $backendServices) {
            $serviceStatus = docker-compose ps $service 2>$null
            if ($serviceStatus -match "Up") {
                Write-Status "✅ $service is running" "success"
            } else {
                Write-Status "❌ $service is not running" "error"
            }
        }
        
        # check metrics
        try {
            $metricsResponse = Invoke-RestMethod -Uri "http://localhost:9090/metrics" -Method Get -TimeoutSec 5
            Write-Status "✅ metrics endpoint is accessible" "success"
        } catch {
            Write-Status "❌ metrics endpoint is not accessible" "error"
        }
        
    } catch {
        Write-Status "❌ status check failed: $($_.Exception.Message)" "error"
    }
}

# main deployment process
Write-Status "environment: $Environment" "info"
Write-Status "config file: $ConfigFile" "info"
Write-Status ""

# check prerequisites
if (!(Test-Prerequisites)) {
    Write-Status "deployment aborted due to missing prerequisites" "error"
    exit 1
}

# generate certificates if requested
if ($GenerateCerts) {
    if (!(Generate-Certificates)) {
        Write-Status "deployment aborted due to certificate generation failure" "error"
        exit 1
    }
}

# build application
if (!(Build-Application)) {
    Write-Status "deployment aborted due to build failure" "error"
    exit 1
}

# build docker image if requested
if ($BuildDocker) {
    if (!(Build-DockerImage)) {
        Write-Status "deployment aborted due to docker build failure" "error"
        exit 1
    }
}

# deploy with docker if requested
if ($DeployDocker) {
    if (!(Deploy-Docker)) {
        Write-Status "deployment aborted due to docker deployment failure" "error"
        exit 1
    }
}

# deploy to kubernetes if requested
if ($DeployKubernetes) {
    if (!(Deploy-Kubernetes)) {
        Write-Status "deployment aborted due to kubernetes deployment failure" "error"
        exit 1
    }
}

# test deployment if not skipped
if (!$SkipTests) {
    if (!(Test-Deployment)) {
        Write-Status "deployment test failed, but deployment may still be functional" "warning"
    }
}

# show final status
Show-Status

Write-Status ""
Write-Status "deployment completed at $(Get-Date)" "info"

if ($DeployDocker) {
    Write-Status ""
    Write-Status "access your load balancer at:" "info"
    Write-Status "  https://localhost:443" "cyan"
    Write-Status "  http://localhost:9090/metrics" "cyan"
    Write-Status "  http://localhost:3000 (grafana)" "cyan"
} 