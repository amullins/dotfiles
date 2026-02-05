# UTF-8 is required for GitHub spec-kit
[Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.Encoding]::UTF8

# oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH/bubbles.omp.json" | Invoke-Expression
Invoke-Expression (&starship init powershell)
starship preset nerd-font-symbols -o "$env:USERPROFILE\.config\starship\starship.toml"

# alias docker to podman
Set-Alias -Name docker -Value podman

# Activate mise automatic environment
mise activate pwsh | Out-String | Invoke-Expression

# Common directories from environment variables
$reposDir = $env:BETENBOUGH_REPOS_ROOT
if(!$reposDir) {
    Write-Warning "Environment variable BETENBOUGH_REPOS_ROOT is not set."
    $reposDir = Read-Host "Please enter the path to the repositories directory"
    # check if it exists
    if(!(Test-Path -Path $reposDir -PathType Container)) {
        Write-Warning "The provided path does not exist or is not a directory. Using the current directory instead."
        $reposDir = Get-Location
    } else {
        Write-Host -ForegroundColor Green "Storing the provided path in the BETENBOUGH_REPOS_ROOT environment variable for future use."
        try {
            [System.Environment]::SetEnvironmentVariable("BETENBOUGH_REPOS_ROOT", $reposDir, [System.EnvironmentVariableTarget]::User)
            Write-Verbose "Set environment variable 'BETENBOUGH_REPOS_ROOT' to '$reposDir'" -Verbose
        }
        catch {
            Write-Error "Failed to set environment variable 'BETENBOUGH_REPOS_ROOT': $_"
        }
    }
}

function RunBetenboughAppHost {
    Invoke-Expression -Command "dotnet run --project $reposDir\betenboughapphost\BetenboughApps.csproj"
}

function ExecuteMigration {
	Invoke-Expression -Command "$reposDir\Main\Databases\CICD\LocalMigration.ps1"
}

function ExecuteRestoreLatest {
	& "$reposDir\dev-utils\ps\database\DbOps.ps1" @args
}

function KillByPort {
    param (
        [Parameter(Mandatory=$true)]
        [int]$port
    )
    $process = Get-NetTCPConnection -LocalPort $port
    if ($null -ne $process) {
        Stop-Process -Id $process.OwningProcess -Force
    }
}

function Invoke-MsBuild {
    # Requires the VSSetup module to be installed
    # https://github.com/microsoft/vssetup.powershell
    # Install-Module VSSetup -Scope CurrentUser 
    param (
        [Parameter(Mandatory=$true)]
        [Boolean]$UsePreview,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Passthrough
    )
    $pattern = if ($UsePreview) { "Preview" } else { "Professional" }
    $vsLocation = "$((Get-VSSetupInstance -All -Prerelease | Where-Object { $_.InstallationPath.EndsWith($pattern) }).InstallationPath)\MSBuild\Current\Bin"
    Write-Host "Using MSBuild from $vsLocation"
    & "$vsLocation\msbuild.exe" @Passthrough
}

function Invoke-VSTest {
    param (
        [Parameter(Mandatory=$true)]
        [Boolean]$UsePreview,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Passthrough
    )
    $pattern = if ($UsePreview) { "Preview" } else { "Professional" }
    $vsLocation = "$((Get-VSSetupInstance -All -Prerelease | Where-Object { $_.InstallationPath.EndsWith($pattern) }).InstallationPath)\Common7\IDE\Extensions\TestPlatform"
    Write-Host "Using VSTest from $vsLocation"
    & "$vsLocation\vstest.console.exe" @Passthrough
}

function BuildSolutions {
    # Get all solution files in the current directory and subdirectories
    $slnFiles = Get-ChildItem -Recurse -Filter *.sln

    # Loop through each solution file and build it
    foreach ($sln in $slnFiles) {
        Write-Host "Building solution: $($sln.FullName)"
        & Invoke-MsBuild -UsePreview $true $sln.FullName /p:Configuration=Debug /m /v:q /nologo /clp:"ErrorsOnly;Summary"
    }
}

function RunTests {
    $mainRepoBase = "$reposDir\Main"
    $testProjects = @(
        "$mainRepoBase\Libraries\Betenbough.Tests.Unit\bin\Debug\Betenbough.Tests.Unit.dll",
        "$mainRepoBase\Libraries\Accounting.Tests.Unit\bin\Debug\Accounting.Tests.Unit.dll",
        "$mainRepoBase\Libraries\Betenbough.Queries.Tests.Unit\bin\Debug\netcoreapp3.1\Betenbough.Queries.Tests.Unit.dll",
        "$mainRepoBase\Apps\BetenboughAPI.Tests\bin\BetenboughAPI.Tests.dll",
        "$mainRepoBase\Cornerstone.ScheduledTaskService\Cornerstone.ScheduledTaskServiceTests\bin\Debug\Cornerstone.ScheduledTaskService.UnitTests.dll")

    $mainRepoBins = Get-ChildItem -Path $mainRepoBase -Recurse -Directory -Filter bin

    # Loop through each solution file and build it
    foreach ($project in $testProjects) {
        $dllPath = [System.IO.Path]::GetDirectoryName($project)
        $matchingBin = $mainRepoBins | Where-Object { $dllPath.StartsWith($_.FullName) }
        $projectName = Split-Path -Path "$(Split-Path -Path $matchingBin -Parent)" -Leaf
        
        if ($matchingBin) {
            Write-Host "Running tests for project: $projectName"
            & Invoke-VSTest -UsePreview $true $project /Settings:local.runsettings /TestAdapterPath:"$($matchingBin.FullName)" /logger:"html;LogFileName=$($projectName)_TestResults.html"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Output "All tests passed successfully."
            } else {
                Write-Output "Some tests failed. Check the output for details."
            }
        }
    }
}

function RunIISExpress {
    param (
        [Parameter(Mandatory=$true)]
        [string]$configFilePath,
        [Parameter(Mandatory=$true)]
        [string]$siteName
    )
    $iisExpress = "C:\Program Files (x86)\IIS Express\iisexpress.exe"
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-noexit -Command `"[Console]::Title='$siteName'; .'$iisExpress' /config:'$configFilePath' /site:'$siteName'`""
}

function RunAccountingAPI {
    RunIISExpress "$reposDir\Main\Solutions\.vs\AccountingAPI\config\applicationhost.config" "AccountingAPI(1)"
}

function RunAPIs {
    param (
        [Parameter(Mandatory=$false)]
        [string]$Apis = 'users,sales,cards,purchasing,construction,communication,warranty,accounting'
    )

    $apiInfo = @{
        users = [System.Tuple]::Create("userservice","UsersAPI")
        sales = [System.Tuple]::Create("salesservice","SalesAPI")
        cards = [System.Tuple]::Create("cardservice","CardsAPI")
        purchasing = [System.Tuple]::Create("purchasingservice","PurchasingAPI")
        construction = [System.Tuple]::Create("constructionservice","ConstructionAPI")
        communication = [System.Tuple]::Create("communicationservice","CommunicationAPI")
        jcs = [System.Tuple]::Create("jobcosting","JobCosting.AzureFunctions")
        warranty = [System.Tuple]::Create("warrantyservice","WarrantyAPI")
        land = [System.Tuple]::Create("landservice","LandAPI")
    };

    function start-api {
        $apilocation = $args[0]
        Set-Location $apilocation
        (git status)[0] -match "On branch (.*)" | Out-Null
        $branch = $matches[1]
        $title = $([System.IO.Path]::GetFileName($apilocation)) + " - " + $branch
        ([System.IO.File]::ReadAllText(([System.IO.Path]::Combine($apilocation,"Properties","launchsettings.json")))) -match "--port (\d+)" | Out-Null
        $port = $matches[1]
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-noexit -Command `"[Console]::Title='$title'; func start --port $port`""
    }

    $apiNames = $Apis.split(",")
    foreach ($api in $apiNames) {
        if ($api -eq "accounting") {
            #Invoke-MsBuild -UsePreview $true -Passthrough "/t:Run"
            RunAccountingAPI
            continue
        }

        $apiServiceDir = "$reposDir\$($apiInfo[$api].Item1)"
        if (![System.IO.Directory]::Exists($apiServiceDir)) {
            Write-Host "Directory for $api not found at $apiServiceDir"
            continue
        }
        $apilocation = "$apiServiceDir\$($apiInfo[$api].Item2)"
        start-api $apilocation
    }
    Write-Host "The specified API(s) have been started"
}
