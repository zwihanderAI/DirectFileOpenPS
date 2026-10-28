#requires -Version 5.1

# 検索対象ディレクトリを指定する。既定値はこのスクリプトの保存先である。
# 設定例: $SearchDirectory = 'C:\pleiades'
#$SearchDirectory = $PSScriptRoot
$SearchDirectory = "E:\"


function GetFileList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$SearchText
    )

    $compareInfo = [System.Globalization.CultureInfo]::GetCultureInfo('ja-JP').CompareInfo
    $compareOptions = [System.Globalization.CompareOptions]::IgnoreCase -bor
        [System.Globalization.CompareOptions]::IgnoreWidth
    $scanErrors = @()

    # IndexOfを使い、*、?、[などもワイルドカードではなく文字として検索する。
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force `
            -ErrorAction SilentlyContinue -ErrorVariable scanErrors |
        Where-Object { $compareInfo.IndexOf($_.Name, $SearchText, $compareOptions) -ge 0 } |
        Sort-Object -Property FullName)

    if ($scanErrors.Count -gt 0) {
        Write-Warning ('読み取れない項目が {0} 件ありました。読み取れた範囲の検索結果を表示します。' -f $scanErrors.Count)
    }

    $files
}

function OpenFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [switch]$OpenDirectory
    )

    if ($OpenDirectory) {
        # 空白や角括弧を含むパスも、単一の引数としてエクスプローラーへ渡す。
        $explorerPath = Join-Path -Path $env:WINDIR -ChildPath 'explorer.exe'
        Start-Process -FilePath $explorerPath -ArgumentList ('"{0}"' -f $File.DirectoryName) -ErrorAction Stop
    }
    else {
        Invoke-Item -LiteralPath $File.FullName -ErrorAction Stop
    }
}

function main {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    try {
        $root = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
        if (-not $root.PSIsContainer -or $root.PSProvider.Name -ne 'FileSystem') {
            throw 'ファイルシステムのディレクトリを指定してください。'
        }
    }
    catch {
        throw ('検索対象ディレクトリを確認できません: {0}{1}{2}' -f $Directory, [Environment]::NewLine, $_.Exception.Message)
    }

    while ($true) {
        Write-Host ''
        Write-Host ('検索対象ディレクトリ: {0}' -f $root.FullName)
        $searchText = Read-Host '検索するファイル名を入力してください（部分一致）'
        if ([string]::IsNullOrWhiteSpace($searchText)) {
            Write-Host 'ファイル名を入力してください。'
            continue
        }

        $files = @(GetFileList -Directory $root.FullName -SearchText $searchText)
        if ($files.Count -eq 0) {
            Write-Host '一致するファイルが見つかりませんでした。'
            continue
        }

        for ($i = 0; $i -lt $files.Count; $i++) {
            Write-Host ('{0}. {1}' -f ($i + 1), $files[$i].FullName)
        }

        while ($true) {
            $selection = (Read-Host '番号を入力してください（番号: ファイルを開く / 番号d: ファイルが格納されているフォルダを開く / 0: 再検索）').Trim()
            $number = 0
            if ($selection -notmatch '^([0-9]+)([dD]?)$') {
                Write-Host '一覧の番号、番号d、または0を入力してください。'
                continue
            }

            $digits = $Matches[1]
            $openDirectory = $Matches[2] -ne ''
            if (-not [int]::TryParse($digits, [ref]$number)) {
                Write-Host '番号が大きすぎます。'
                continue
            }
            if ($number -eq 0 -and -not $openDirectory) {
                break
            }
            if ($number -lt 1 -or $number -gt $files.Count) {
                Write-Host ('1から{0}までの番号を入力してください。再検索する場合は0を入力してください。' -f $files.Count)
                continue
            }

            try {
                OpenFile -File $files[$number - 1] -OpenDirectory:$openDirectory
            }
            catch {
                Write-Warning ('開く処理に失敗しました: {0}' -f $_.Exception.Message)
            }
        }
    }
}

# ドットソース時は関数定義のみを読み込む。通常実行時は入力待ちを開始する。
if ($MyInvocation.InvocationName -ne '.') {
    main -Directory $SearchDirectory
}
