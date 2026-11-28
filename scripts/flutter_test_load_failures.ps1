# 从 flutter test 的 JSON 事件流里分出两类失败：
#   1. LoadFailures —— 整个测试文件没跑起来（`loading <file>` 伪用例报 error）。
#      典型是 flutter_tester 的 WebSocket 握手失败（Windows runner 上偶发），
#      与被测代码无关，重试通常即过。
#   2. TestFailures —— 真的有用例断言失败（含超时、异常）。
# 只有「LoadFailures 非空且 TestFailures 为空」才允许重试：否则重试会掩盖真实失败。
function Get-FlutterTestFailureReport {
    param([Parameter(Mandatory)][string]$EventsPath)

    $loadFailures = [System.Collections.Generic.List[string]]::new()
    $testFailures = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $EventsPath)) {
        return [pscustomobject]@{ LoadFailures = @(); TestFailures = @() }
    }

    $loadingNames = @{}
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'testStart' -and $event.test.name -like 'loading *') {
            $loadingNames[[int]$event.test.id] = $event.test.name.Substring(8).Trim()
        } elseif ($event.type -eq 'testDone' -and $event.result -eq 'error') {
            $id = [int]$event.testID
            if ($loadingNames.ContainsKey($id)) { $loadFailures.Add($loadingNames[$id]) }
            else { $testFailures.Add('test #' + $id) }
        }
    }

    return [pscustomobject]@{
        LoadFailures = @($loadFailures | Select-Object -Unique)
        TestFailures = @($testFailures | Select-Object -Unique)
    }
}
