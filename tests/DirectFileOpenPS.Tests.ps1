#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DirectFileOpenPS.ps1')

$testState = @{}
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('検証失敗: ' + $Message) }
    $script:assertions++
}

$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempParent ('DirectFileOpenPS.Tests-' + [guid]::NewGuid().ToString('N'))

try {
    $nested = Join-Path $testRoot '深い階層\空白 [test]\さらに下'
    $null = New-Item -ItemType Directory -Path $nested -Force
    $wideFile = Join-Path $nested 'ＡＢＣ_カタカナ_ガイド.txt'
    $asciiFile = Join-Path $testRoot 'abc.txt'
    $singleFile = Join-Path $nested 'single.txt'
    foreach ($path in @($wideFile, $asciiFile, $singleFile, (Join-Path $nested '[literal].txt'))) {
        [System.IO.File]::WriteAllText($path, 'fixture')
    }
    $folderOnly = Join-Path $testRoot 'DirectoryOnly'
    $null = New-Item -ItemType Directory -Path $folderOnly
    [System.IO.File]::WriteAllText((Join-Path $folderOnly 'unrelated.txt'), 'fixture')
    $hiddenFile = Join-Path $testRoot 'hidden.txt'
    [System.IO.File]::WriteAllText($hiddenFile, 'fixture')
    [System.IO.File]::SetAttributes($hiddenFile, [System.IO.FileAttributes]::Hidden)

    $results = @(Find-DirectFile -Directory $testRoot -SearchText 'AbC')
    Assert-True ($results.Count -eq 2) '深い階層を含め、大文字・小文字と半角・全角を区別せず検索する'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText 'ａｂＣ').Count -eq 2) '全角の検索文字列でも半角名に一致する'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText 'ｶﾀｶﾅ').Count -eq 1) '半角カタカナが全角カタカナに一致する'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText 'ｶﾞｲﾄﾞ').Count -eq 1) '濁点付き半角カタカナが全角名に一致する'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText '[literal]').Count -eq 1) '角括弧をリテラルとして検索する'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText '*').Count -eq 0) 'アスタリスクで全件一致しない'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText '?').Count -eq 0) '疑問符をワイルドカードにしない'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText 'DirectoryOnly').Count -eq 0) 'フォルダ名と親パスでは検索しない'
    Assert-True (@(Find-DirectFile -Directory $testRoot -SearchText 'hidden').Count -eq 1) '隠しファイルを検索する'
    Assert-True (@(Find-DirectFile -Directory $nested -SearchText 'single').Count -eq 1) '空白と角括弧を含む検索対象パスを扱う'
    Assert-True (($results.FullName -join '|') -eq (($results.FullName | Sort-Object) -join '|')) 'フルパス順で結果を並べる'

    $testState.fileCalls = New-Object 'System.Collections.Generic.List[string]'
    $testState.folderCalls = New-Object 'System.Collections.Generic.List[string]'
    $testState.outputLines = New-Object 'System.Collections.Generic.List[string]'
    $testState.warningLines = New-Object 'System.Collections.Generic.List[string]'
    $testState.failNextOpen = $false

    function Invoke-Item {
        [CmdletBinding()]
        param([string]$LiteralPath)
        $testState.fileCalls.Add($LiteralPath)
        if ($testState.failNextOpen) {
            $testState.failNextOpen = $false
            throw '起動失敗のテスト'
        }
    }
    function Start-Process {
        [CmdletBinding()]
        param([string]$FilePath, [string[]]$ArgumentList)
        Assert-True ($FilePath -eq (Join-Path $env:WINDIR 'explorer.exe')) 'エクスプローラーを指定する'
        Assert-True ($ArgumentList.Count -eq 1) 'フォルダパスを単一引数で渡す'
        $testState.folderCalls.Add($ArgumentList[0])
    }
    function Write-Host {
        param($Object)
        $testState.outputLines.Add([string]$Object)
    }
    function Write-Warning {
        [CmdletBinding()]
        param([string]$Message)
        $testState.warningLines.Add($Message)
    }

    Open-DirectFile -File (Get-Item -LiteralPath $wideFile)
    Open-DirectFile -File (Get-Item -LiteralPath $wideFile) -OpenDirectory
    Assert-True ($testState.fileCalls[0] -eq $wideFile) '既定のプログラム起動へリテラルのフルパスを渡す'
    Assert-True ($testState.folderCalls[0] -eq ('"{0}"' -f $nested)) '保存先フォルダの空白と角括弧を保持して引用する'
    $testState.fileCalls.Clear()
    $testState.folderCalls.Clear()

    $testState.inputs = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($value in @('', '存在しない名前', 'abc', '', '-1', 'text', '0d', '999999999999999', '99', '1', '1d', '1D', '1', '0', 'single', '1', '0')) {
        $testState.inputs.Enqueue($value)
    }
    $testState.prompts = New-Object 'System.Collections.Generic.List[string]'
    function Read-Host {
        param([string]$Prompt)
        $testState.prompts.Add($Prompt)
        if ($testState.inputs.Count -eq 0) { throw [System.OperationCanceledException]::new('入力列の終端') }
        $testState.inputs.Dequeue()
    }

    $testState.failNextOpen = $true
    $reachedEnd = $false
    try { Start-DirectFileOpen -Directory $testRoot }
    catch [System.OperationCanceledException] { $reachedEnd = $true }
    Assert-True $reachedEnd '不正入力と起動失敗後も処理を継続し、全入力を消化する'
    Assert-True ($testState.fileCalls.Count -eq 3) '番号での起動を繰り返し、再検索後も起動できる'
    Assert-True ($testState.fileCalls[0] -eq $results[0].FullName) '一覧の番号と対象ファイルを対応させる'
    Assert-True ($testState.fileCalls[2] -eq $singleFile) '結果が1件の場合も番号で起動できる'
    Assert-True ($testState.folderCalls.Count -eq 2) '小文字dと大文字Dでフォルダを起動できる'
    Assert-True (@($testState.prompts | Where-Object { $_ -eq '検索するファイル名（部分一致）' }).Count -eq 5) '空入力、該当なし、0で検索入力に戻る'
    Assert-True (@($testState.outputLines | Where-Object { $_ -eq ('1. ' + $results[0].FullName) }).Count -eq 1) '番号とフルパスを表示する'
    Assert-True (@($testState.outputLines | Where-Object { $_ -eq ('検索対象ディレクトリ: ' + $testRoot) }).Count -eq 5) '検索の前に対象ディレクトリを表示する'
    Assert-True (@($testState.warningLines | Where-Object { $_ -like '*起動失敗のテスト*' }).Count -eq 1) '起動失敗を警告する'

    foreach ($invalidRoot in @((Join-Path $testRoot 'missing'), $singleFile)) {
        $rejected = $false
        try { Start-DirectFileOpen -Directory $invalidRoot }
        catch { $rejected = $_.Exception.Message -like '*検索対象ディレクトリを確認できない*' }
        Assert-True $rejected '存在しないパスとファイルの指定を開始時に拒否する'
    }

    # 列挙エラーが発生した場合も、警告して結果を返すことを確認する。
    $testState.warningLines.Clear()
    $remainingResults = @(Find-DirectFile -Directory (Join-Path $testRoot 'missing') -SearchText 'abc')
    Assert-True ($remainingResults.Count -eq 0 -and $testState.warningLines.Count -eq 1) '列挙エラーを警告し、検索処理を継続する'

    $testState.inputs.Enqueue('README')
    $testState.inputs.Enqueue('0')
    $testState.outputLines.Clear()
    $reachedEnd = $false
    try { & (Join-Path (Split-Path -Parent $PSScriptRoot) 'DirectFileOpenPS.ps1') }
    catch [System.OperationCanceledException] { $reachedEnd = $true }
    Assert-True ($reachedEnd -and $testState.inputs.Count -eq 0) '通常実行で設定値を使って検索と番号入力を開始する'
    Assert-True ($testState.outputLines.Contains('1. ' + (Join-Path (Split-Path -Parent $PSScriptRoot) 'README.md'))) '通常実行で検索結果のフルパスを表示する'

    [Console]::WriteLine(('成功: {0} 件の検証 (PowerShell {1})' -f $script:assertions, $PSVersionTable.PSVersion))
}
finally {
    # 削除対象が、このテストで作成した一時ディレクトリであることを確認する。
    $resolvedRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ([System.IO.Path]::GetDirectoryName($resolvedRoot) -ne $tempParent -or
        [System.IO.Path]::GetFileName($resolvedRoot) -notmatch '^DirectFileOpenPS\.Tests-[0-9a-f]{32}$') {
        throw '一時ディレクトリの削除対象が不正である。'
    }
    if (Test-Path -LiteralPath $resolvedRoot) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
