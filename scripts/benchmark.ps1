# benchmark script for the production https load balancer
# this script performs comprehensive performance testing

param(
    [string]$LoadBalancerUrl = "https://localhost:443",
    [int]$Duration = 300,
    [int]$ConcurrentUsers = 50,
    [int]$RampUpTime = 60,
    [string]$OutputFile = "benchmark-results.json"
)

Write-Host "🚀 starting load balancer benchmark..." -ForegroundColor Green

# benchmark configuration
$config = @{
    LoadBalancerUrl = $LoadBalancerUrl
    Duration = $Duration
    ConcurrentUsers = $ConcurrentUsers
    RampUpTime = $RampUpTime
    StartTime = Get-Date
}

# results storage
$results = @{
    config = $config
    tests = @()
    summary = @{}
}

function Test-BasicPerformance {
    Write-Host "testing basic performance..." -ForegroundColor Yellow
    
    $testResults = @{
        name = "basic_performance"
        requests = 0
        successful = 0
        failed = 0
        response_times = @()
        start_time = Get-Date
    }
    
    $totalRequests = 1000
    
    for ($i = 0; $i -lt $totalRequests; $i++) {
        $startTime = Get-Date
        try {
            $response = Invoke-WebRequest -Uri $LoadBalancerUrl -Method Get -SkipCertificateCheck
            $endTime = Get-Date
            $responseTime = ($endTime - $startTime).TotalMilliseconds
            
            $testResults.successful++
            $testResults.response_times += $responseTime
            
            if ($i % 100 -eq 0) {
                Write-Host "  completed $i requests" -ForegroundColor Cyan
            }
        } catch {
            $testResults.failed++
        }
        $testResults.requests++
        
        Start-Sleep -Milliseconds 10
    }
    
    $testResults.end_time = Get-Date
    $testResults.duration = ($testResults.end_time - $testResults.start_time).TotalSeconds
    $testResults.success_rate = [math]::Round(($testResults.successful / $testResults.requests) * 100, 2)
    $testResults.avg_response_time = if ($testResults.response_times.Count -gt 0) { 
        [math]::Round(($testResults.response_times | Measure-Object -Average).Average, 2) 
    } else { 0 }
    $testResults.requests_per_second = [math]::Round($testResults.requests / $testResults.duration, 2)
    
    Write-Host "  requests: $($testResults.requests)" -ForegroundColor Green
    Write-Host "  success rate: $($testResults.success_rate)%" -ForegroundColor Green
    Write-Host "  avg response time: $($testResults.avg_response_time)ms" -ForegroundColor Green
    Write-Host "  requests/sec: $($testResults.requests_per_second)" -ForegroundColor Green
    
    return $testResults
}

function Test-ConcurrentLoad {
    Write-Host "testing concurrent load ($ConcurrentUsers users for $Duration seconds)..." -ForegroundColor Yellow
    
    $testResults = @{
        name = "concurrent_load"
        total_requests = 0
        total_successful = 0
        total_failed = 0
        response_times = @()
        start_time = Get-Date
        user_results = @()
    }
    
    $jobs = @()
    $endTime = (Get-Date).AddSeconds($Duration)
    
    # start concurrent users
    for ($user = 1; $user -le $ConcurrentUsers; $user++) {
        $job = Start-Job -ScriptBlock {
            param($url, $userId, $endTime)
            
            $userResults = @{
                user_id = $userId
                requests = 0
                successful = 0
                failed = 0
                response_times = @()
                errors = @()
            }
            
            while ((Get-Date) -lt $endTime) {
                $startTime = Get-Date
                try {
                    $response = Invoke-WebRequest -Uri $url -Method Get -SkipCertificateCheck
                    $endTime = Get-Date
                    $responseTime = ($endTime - $startTime).TotalMilliseconds
                    
                    $userResults.successful++
                    $userResults.response_times += $responseTime
                } catch {
                    $userResults.failed++
                    $userResults.errors += $_.Exception.Message
                }
                $userResults.requests++
                
                Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
            }
            
            return $userResults
        } -ArgumentList $LoadBalancerUrl, $user, $endTime
        
        $jobs += $job
    }
    
    # wait for all jobs to complete
    Wait-Job -Job $jobs | Out-Null
    
    # collect results
    foreach ($job in $jobs) {
        $userResult = Receive-Job -Job $job
        $testResults.user_results += $userResult
        $testResults.total_requests += $userResult.requests
        $testResults.total_successful += $userResult.successful
        $testResults.total_failed += $userResult.failed
        $testResults.response_times += $userResult.response_times
        Remove-Job -Job $job
    }
    
    $testResults.end_time = Get-Date
    $testResults.duration = ($testResults.end_time - $testResults.start_time).TotalSeconds
    $testResults.success_rate = [math]::Round(($testResults.total_successful / $testResults.total_requests) * 100, 2)
    $testResults.avg_response_time = if ($testResults.response_times.Count -gt 0) { 
        [math]::Round(($testResults.response_times | Measure-Object -Average).Average, 2) 
    } else { 0 }
    $testResults.requests_per_second = [math]::Round($testResults.total_requests / $testResults.duration, 2)
    $testResults.throughput = [math]::Round($testResults.total_successful / $testResults.duration, 2)
    
    Write-Host "  total requests: $($testResults.total_requests)" -ForegroundColor Green
    Write-Host "  success rate: $($testResults.success_rate)%" -ForegroundColor Green
    Write-Host "  avg response time: $($testResults.avg_response_time)ms" -ForegroundColor Green
    Write-Host "  requests/sec: $($testResults.requests_per_second)" -ForegroundColor Green
    Write-Host "  throughput: $($testResults.throughput) req/sec" -ForegroundColor Green
    
    return $testResults
}

function Test-StressTest {
    Write-Host "testing stress conditions..." -ForegroundColor Yellow
    
    $testResults = @{
        name = "stress_test"
        phases = @()
        start_time = Get-Date
    }
    
    # phase 1: normal load
    Write-Host "  phase 1: normal load (30 seconds)" -ForegroundColor Cyan
    $phase1 = Test-LoadPhase -Duration 30 -ConcurrentUsers 10 -PhaseName "normal_load"
    $testResults.phases += $phase1
    
    # phase 2: high load
    Write-Host "  phase 2: high load (30 seconds)" -ForegroundColor Cyan
    $phase2 = Test-LoadPhase -Duration 30 -ConcurrentUsers 100 -PhaseName "high_load"
    $testResults.phases += $phase2
    
    # phase 3: burst load
    Write-Host "  phase 3: burst load (30 seconds)" -ForegroundColor Cyan
    $phase3 = Test-LoadPhase -Duration 30 -ConcurrentUsers 200 -PhaseName "burst_load"
    $testResults.phases += $phase3
    
    # phase 4: recovery
    Write-Host "  phase 4: recovery (30 seconds)" -ForegroundColor Cyan
    $phase4 = Test-LoadPhase -Duration 30 -ConcurrentUsers 10 -PhaseName "recovery"
    $testResults.phases += $phase4
    
    $testResults.end_time = Get-Date
    $testResults.duration = ($testResults.end_time - $testResults.start_time).TotalSeconds
    
    return $testResults
}

function Test-LoadPhase {
    param(
        [int]$Duration,
        [int]$ConcurrentUsers,
        [string]$PhaseName
    )
    
    $phaseResults = @{
        name = $PhaseName
        duration = $Duration
        concurrent_users = $ConcurrentUsers
        requests = 0
        successful = 0
        failed = 0
        response_times = @()
        start_time = Get-Date
    }
    
    $jobs = @()
    $endTime = (Get-Date).AddSeconds($Duration)
    
    for ($user = 1; $user -le $ConcurrentUsers; $user++) {
        $job = Start-Job -ScriptBlock {
            param($url, $userId, $endTime)
            
            $userRequests = 0
            $userSuccessful = 0
            $userFailed = 0
            $userResponseTimes = @()
            
            while ((Get-Date) -lt $endTime) {
                $startTime = Get-Date
                try {
                    $response = Invoke-WebRequest -Uri $url -Method Get -SkipCertificateCheck
                    $endTime = Get-Date
                    $responseTime = ($endTime - $startTime).TotalMilliseconds
                    
                    $userSuccessful++
                    $userResponseTimes += $responseTime
                } catch {
                    $userFailed++
                }
                $userRequests++
                
                Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 100)
            }
            
            return @{
                requests = $userRequests
                successful = $userSuccessful
                failed = $userFailed
                response_times = $userResponseTimes
            }
        } -ArgumentList $LoadBalancerUrl, $user, $endTime
        
        $jobs += $job
    }
    
    Wait-Job -Job $jobs | Out-Null
    
    foreach ($job in $jobs) {
        $userResult = Receive-Job -Job $job
        $phaseResults.requests += $userResult.requests
        $phaseResults.successful += $userResult.successful
        $phaseResults.failed += $userResult.failed
        $phaseResults.response_times += $userResult.response_times
        Remove-Job -Job $job
    }
    
    $phaseResults.end_time = Get-Date
    $phaseResults.duration = ($phaseResults.end_time - $phaseResults.start_time).TotalSeconds
    $phaseResults.success_rate = [math]::Round(($phaseResults.successful / $phaseResults.requests) * 100, 2)
    $phaseResults.avg_response_time = if ($phaseResults.response_times.Count -gt 0) { 
        [math]::Round(($phaseResults.response_times | Measure-Object -Average).Average, 2) 
    } else { 0 }
    $phaseResults.requests_per_second = [math]::Round($phaseResults.requests / $phaseResults.duration, 2)
    
    return $phaseResults
}

function Test-MemoryUsage {
    Write-Host "testing memory usage..." -ForegroundColor Yellow
    
    $testResults = @{
        name = "memory_usage"
        measurements = @()
        start_time = Get-Date
    }
    
    # monitor memory usage during load test
    $monitoringJob = Start-Job -ScriptBlock {
        param($duration)
        
        $measurements = @()
        $endTime = (Get-Date).AddSeconds($duration)
        
        while ((Get-Date) -lt $endTime) {
            $process = Get-Process -Name "rust-load" -ErrorAction SilentlyContinue
            if ($process) {
                $measurements += @{
                    timestamp = Get-Date
                    memory_mb = [math]::Round($process.WorkingSet64 / 1MB, 2)
                    cpu_percent = $process.CPU
                }
            }
            Start-Sleep -Seconds 5
        }
        
        return $measurements
    } -ArgumentList $Duration
    
    # run load test while monitoring
    $loadJob = Start-Job -ScriptBlock {
        param($url, $duration)
        
        $requests = 0
        $endTime = (Get-Date).AddSeconds($duration)
        
        while ((Get-Date) -lt $endTime) {
            try {
                Invoke-WebRequest -Uri $url -Method Get -SkipCertificateCheck | Out-Null
                $requests++
            } catch {
                # ignore errors for memory test
            }
            Start-Sleep -Milliseconds 100
        }
        
        return $requests
    } -ArgumentList $LoadBalancerUrl, $Duration
    
    Wait-Job -Job $monitoringJob, $loadJob | Out-Null
    
    $testResults.measurements = Receive-Job -Job $monitoringJob
    $testResults.total_requests = Receive-Job -Job $loadJob
    
    Remove-Job -Job $monitoringJob, $loadJob
    
    $testResults.end_time = Get-Date
    $testResults.duration = ($testResults.end_time - $testResults.start_time).TotalSeconds
    
    if ($testResults.measurements.Count -gt 0) {
        $avgMemory = ($testResults.measurements | ForEach-Object { $_.memory_mb } | Measure-Object -Average).Average
        $maxMemory = ($testResults.measurements | ForEach-Object { $_.memory_mb } | Measure-Object -Maximum).Maximum
        $testResults.avg_memory_mb = [math]::Round($avgMemory, 2)
        $testResults.max_memory_mb = [math]::Round($maxMemory, 2)
        
        Write-Host "  avg memory usage: $($testResults.avg_memory_mb) mb" -ForegroundColor Green
        Write-Host "  max memory usage: $($testResults.max_memory_mb) mb" -ForegroundColor Green
    }
    
    return $testResults
}

# run all benchmark tests
$tests = @(
    @{ Name = "Basic Performance"; Function = "Test-BasicPerformance" }
    @{ Name = "Concurrent Load"; Function = "Test-ConcurrentLoad" }
    @{ Name = "Stress Test"; Function = "Test-StressTest" }
    @{ Name = "Memory Usage"; Function = "Test-MemoryUsage" }
)

foreach ($test in $tests) {
    Write-Host ""
    Write-Host "running benchmark: $($test.Name)" -ForegroundColor Green
    $result = & $test.Function
    $results.tests += $result
}

# generate summary
$results.summary = @{
    total_tests = $results.tests.Count
    total_requests = ($results.tests | ForEach-Object { $_.requests } | Measure-Object -Sum).Sum
    avg_success_rate = [math]::Round(($results.tests | ForEach-Object { $_.success_rate } | Measure-Object -Average).Average, 2)
    avg_response_time = [math]::Round(($results.tests | ForEach-Object { $_.avg_response_time } | Measure-Object -Average).Average, 2)
    max_requests_per_second = ($results.tests | ForEach-Object { $_.requests_per_second } | Measure-Object -Maximum).Maximum
    benchmark_duration = ((Get-Date) - $config.StartTime).TotalSeconds
}

# save results
$results | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputFile -Encoding UTF8

# display summary
Write-Host ""
Write-Host "benchmark summary:" -ForegroundColor Green
Write-Host "  total tests: $($results.summary.total_tests)" -ForegroundColor Cyan
Write-Host "  total requests: $($results.summary.total_requests)" -ForegroundColor Cyan
Write-Host "  avg success rate: $($results.summary.avg_success_rate)%" -ForegroundColor Cyan
Write-Host "  avg response time: $($results.summary.avg_response_time)ms" -ForegroundColor Cyan
Write-Host "  max requests/sec: $($results.summary.max_requests_per_second)" -ForegroundColor Cyan
Write-Host "  benchmark duration: $($results.summary.benchmark_duration)s" -ForegroundColor Cyan
Write-Host ""
Write-Host "results saved to: $OutputFile" -ForegroundColor Green 