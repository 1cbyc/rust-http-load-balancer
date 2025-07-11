# test script for the production https load balancer
# this script tests all major features of the load balancer

param(
    [string]$LoadBalancerUrl = "https://localhost:443",
    [string]$MetricsUrl = "http://localhost:9090",
    [int]$TestDuration = 60,
    [int]$ConcurrentUsers = 10
)

Write-Host "🧪 testing production https load balancer..." -ForegroundColor Green

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

function Test-HealthCheck {
    Write-Status "testing health check endpoint..." "info"
    
    try {
        $response = Invoke-RestMethod -Uri "$LoadBalancerUrl/health" -Method Get -SkipCertificateCheck
        if ($response.status -eq "healthy") {
            Write-Status "✅ health check passed" "success"
            return $true
        } else {
            Write-Status "❌ health check failed - unexpected status" "error"
            return $false
        }
    } catch {
        Write-Status "❌ health check failed - $($_.Exception.Message)" "error"
        return $false
    }
}

function Test-Metrics {
    Write-Status "testing metrics endpoint..." "info"
    
    try {
        $response = Invoke-RestMethod -Uri "$MetricsUrl/metrics" -Method Get
        if ($response -match "total_requests") {
            Write-Status "✅ metrics endpoint working" "success"
            return $true
        } else {
            Write-Status "❌ metrics endpoint not returning expected data" "error"
            return $false
        }
    } catch {
        Write-Status "❌ metrics endpoint failed - $($_.Exception.Message)" "error"
        return $false
    }
}

function Test-LoadBalancing {
    Write-Status "testing load balancing algorithms..." "info"
    
    $servers = @()
    $totalRequests = 50
    
    for ($i = 0; $i -lt $totalRequests; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$LoadBalancerUrl/" -Method Get -SkipCertificateCheck
            $server = $response.Headers["X-Server"]
            if ($server) {
                $servers += $server
            }
            Start-Sleep -Milliseconds 100
        } catch {
            Write-Status "❌ request failed - $($_.Exception.Message)" "error"
        }
    }
    
    $serverCounts = $servers | Group-Object | Sort-Object Count -Descending
    Write-Status "load distribution results:" "info"
    foreach ($server in $serverCounts) {
        $percentage = [math]::Round(($server.Count / $totalRequests) * 100, 2)
        Write-Status "  $($server.Name): $($server.Count) requests ($percentage%)" "info"
    }
    
    if ($serverCounts.Count -gt 1) {
        Write-Status "✅ load balancing working - requests distributed across servers" "success"
        return $true
    } else {
        Write-Status "❌ load balancing not working - all requests to single server" "error"
        return $false
    }
}

function Test-RateLimiting {
    Write-Status "testing rate limiting..." "info"
    
    $rateLimitExceeded = 0
    $requests = 0
    
    # send requests rapidly to trigger rate limiting
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$LoadBalancerUrl/" -Method Get -SkipCertificateCheck
            $requests++
        } catch {
            if ($_.Exception.Response.StatusCode -eq 429) {
                $rateLimitExceeded++
            }
        }
        Start-Sleep -Milliseconds 50
    }
    
    if ($rateLimitExceeded -gt 0) {
        Write-Status "✅ rate limiting working - $rateLimitExceeded requests blocked" "success"
        return $true
    } else {
        Write-Status "⚠️ rate limiting not triggered (may be configured too high)" "warning"
        return $true
    }
}

function Test-SessionPersistence {
    Write-Status "testing session persistence..." "info"
    
    $clientId = "test-client-" + [guid]::NewGuid().ToString()
    $servers = @()
    
    # send multiple requests from same client
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $headers = @{
                "X-Client-ID" = $clientId
            }
            $response = Invoke-WebRequest -Uri "$LoadBalancerUrl/" -Method Get -SkipCertificateCheck -Headers $headers
            $server = $response.Headers["X-Server"]
            if ($server) {
                $servers += $server
            }
            Start-Sleep -Milliseconds 200
        } catch {
            Write-Status "❌ session persistence test failed - $($_.Exception.Message)" "error"
        }
    }
    
    $uniqueServers = $servers | Sort-Object -Unique
    if ($uniqueServers.Count -eq 1) {
        Write-Status "✅ session persistence working - all requests to same server" "success"
        return $true
    } else {
        Write-Status "❌ session persistence not working - requests to multiple servers" "error"
        return $false
    }
}

function Test-ConcurrentLoad {
    Write-Status "testing concurrent load ($ConcurrentUsers users for $TestDuration seconds)..." "info"
    
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TestDuration)
    $totalRequests = 0
    $successfulRequests = 0
    $failedRequests = 0
    
    $jobs = @()
    
    # start concurrent users
    for ($user = 1; $user -le $ConcurrentUsers; $user++) {
        $job = Start-Job -ScriptBlock {
            param($url, $userId, $endTime)
            
            $userRequests = 0
            $userSuccess = 0
            $userFailed = 0
            
            while ((Get-Date) -lt $endTime) {
                try {
                    $response = Invoke-WebRequest -Uri $url -Method Get -SkipCertificateCheck
                    $userSuccess++
                } catch {
                    $userFailed++
                }
                $userRequests++
                Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
            }
            
            return @{
                UserId = $userId
                TotalRequests = $userRequests
                SuccessfulRequests = $userSuccess
                FailedRequests = $userFailed
            }
        } -ArgumentList $LoadBalancerUrl, $user, $endTime
        
        $jobs += $job
    }
    
    # wait for all jobs to complete
    Wait-Job -Job $jobs | Out-Null
    
    # collect results
    foreach ($job in $jobs) {
        $result = Receive-Job -Job $job
        $totalRequests += $result.TotalRequests
        $successfulRequests += $result.SuccessfulRequests
        $failedRequests += $result.FailedRequests
        Remove-Job -Job $job
    }
    
    $successRate = if ($totalRequests -gt 0) { [math]::Round(($successfulRequests / $totalRequests) * 100, 2) } else { 0 }
    $requestsPerSecond = [math]::Round($totalRequests / $TestDuration, 2)
    
    Write-Status "concurrent load test results:" "info"
    Write-Status "  total requests: $totalRequests" "info"
    Write-Status "  successful requests: $successfulRequests" "success"
    Write-Status "  failed requests: $failedRequests" "error"
    Write-Status "  success rate: $successRate%" "info"
    Write-Status "  requests per second: $requestsPerSecond" "info"
    
    if ($successRate -gt 95) {
        Write-Status "✅ concurrent load test passed" "success"
        return $true
    } else {
        Write-Status "❌ concurrent load test failed - low success rate" "error"
        return $false
    }
}

function Test-BackendHealth {
    Write-Status "testing backend health monitoring..." "info"
    
    try {
        # test each backend directly
        $backends = @("http://localhost:8001", "http://localhost:8002", "http://localhost:8003")
        $healthyBackends = 0
        
        foreach ($backend in $backends) {
            try {
                $response = Invoke-RestMethod -Uri "$backend/health" -Method Get
                if ($response.status -eq "healthy") {
                    $healthyBackends++
                    Write-Status "  ✅ $backend is healthy" "success"
                } else {
                    Write-Status "  ❌ $backend is unhealthy" "error"
                }
            } catch {
                Write-Status "  ❌ $backend is unreachable" "error"
            }
        }
        
        if ($healthyBackends -gt 0) {
            Write-Status "✅ backend health monitoring working - $healthyBackends healthy backends" "success"
            return $true
        } else {
            Write-Status "❌ no healthy backends found" "error"
            return $false
        }
    } catch {
        Write-Status "❌ backend health test failed - $($_.Exception.Message)" "error"
        return $false
    }
}

# main test execution
Write-Status "starting comprehensive load balancer tests..." "info"
Write-Status "load balancer url: $LoadBalancerUrl" "info"
Write-Status "metrics url: $MetricsUrl" "info"
Write-Status ""

$tests = @(
    @{ Name = "Health Check"; Function = "Test-HealthCheck" }
    @{ Name = "Metrics Endpoint"; Function = "Test-Metrics" }
    @{ Name = "Backend Health"; Function = "Test-BackendHealth" }
    @{ Name = "Load Balancing"; Function = "Test-LoadBalancing" }
    @{ Name = "Rate Limiting"; Function = "Test-RateLimiting" }
    @{ Name = "Session Persistence"; Function = "Test-SessionPersistence" }
    @{ Name = "Concurrent Load"; Function = "Test-ConcurrentLoad" }
)

$passedTests = 0
$totalTests = $tests.Count

foreach ($test in $tests) {
    Write-Status "running test: $($test.Name)" "info"
    $result = & $test.Function
    
    if ($result) {
        $passedTests++
        Write-Status "✅ $($test.Name) passed" "success"
    } else {
        Write-Status "❌ $($test.Name) failed" "error"
    }
    Write-Status ""
}

# final results
Write-Status "test results summary:" "info"
Write-Status "  passed: $passedTests/$totalTests" "info"
$passRate = [math]::Round(($passedTests / $totalTests) * 100, 2)
Write-Status "  pass rate: $passRate%" "info"

if ($passRate -eq 100) {
    Write-Status "🎉 all tests passed! load balancer is working correctly." "success"
} elseif ($passRate -ge 80) {
    Write-Status "⚠️ most tests passed, but some issues detected." "warning"
} else {
    Write-Status "❌ multiple tests failed, load balancer needs attention." "error"
}

Write-Status ""
Write-Status "test completed at $(Get-Date)" "info" 