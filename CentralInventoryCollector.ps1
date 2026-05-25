param(
    [string]$CustomerName      = "<Insert customer name here/ can be left empty>",

    [string]$SubscriptionId    = "<Insert customer subscription id here/ can be left empty>",
    [string]$AutomationRG      = "<Insert customer RG name here/ can be left empty>",
    [string]$AutomationAccount = "<Insert customer automation account name here/ can be left empty>",
    [string]$RunbookName       = "OnPremInventory",

    [string]$WorkspaceRG       = "rg-monitor",
    [string]$WorkspaceName     = "log-monitor"
)

# ============================================================
# 0. Autentisering och kontext
# ============================================================
Connect-AzAccount -Identity
Set-AzContext -Subscription $SubscriptionId

# ============================================================
# 1. Hämta senaste OnPremInventory-jobbet och dess JSON-output
# ============================================================
$job = Get-AzAutomationJob `
    -ResourceGroupName $AutomationRG `
    -AutomationAccountName $AutomationAccount `
    -RunbookName $RunbookName `
    | Sort-Object CreationTime -Descending `
    | Select-Object -First 1

if (-not $job) { throw "Inget jobb hittades för runbook '$RunbookName'." }

$output = Get-AzAutomationJobOutput `
    -ResourceGroupName $AutomationRG `
    -AutomationAccountName $AutomationAccount `
    -Id $job.JobId `
    -Stream Output

$lines = $output.Summary
$json  = $lines | Sort-Object Length -Descending | Select-Object -First 1
$data  = $json | ConvertFrom-Json

# Konvertera gamla /Date(...)\/-datum till riktiga DateTime
foreach ($item in $data) {
    foreach ($prop in $item.PSObject.Properties) {
        if ($prop.Value -is [string] -and $prop.Value -match "\/Date\((\d+)\)\/") {
            $ticks = [int64]$Matches[1]
            $prop.Value = (Get-Date "1970-01-01").AddMilliseconds($ticks)
        }
    }
}

# Normalisera AD-inventering
$ADInventory = foreach ($a in $data) {
    [PSCustomObject]@{
        ComputerName      = ($a.ComputerName -split '\.')[0].ToLower()
        OperatingSystem   = $a.OperatingSystem
        DistinguishedName = $a.DistinguishedName
        Source            = "ActiveDirectory"
    }
}

# ============================================================
# 2. Hämta Heartbeat från Log Analytics
# ============================================================
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $WorkspaceRG `
    -Name $WorkspaceName

$query = @"
Heartbeat
| summarize arg_max(TimeGenerated, *) by Computer
| project Computer, TimeGenerated
"@

$hbQuery = Invoke-AzOperationalInsightsQuery `
    -WorkspaceId $workspace.CustomerId `
    -Query $query

$heartbeatClean = $hbQuery.Results | ForEach-Object {
    [PSCustomObject]@{
        Computer      = ($_.Computer -split '\.')[0].ToLower()
        TimeGenerated = $_.TimeGenerated
    }
}

# ============================================================
# 3. Hämta Azure VM-inventering
# ============================================================
$AzureVMInventory = Get-AzVM -Status | ForEach-Object {
    [PSCustomObject]@{
        ComputerName  = ($_.OsProfile.ComputerName -split '\.')[0].ToLower()
        VmName        = $_.Name
        ResourceGroup = $_.ResourceGroupName
        Location      = $_.Location
        VmId          = $_.VmId
        Source        = "AzureVM"
    }
}

# ============================================================
# 4. Hämta Azure Arc-inventering via REST
# ============================================================
$token   = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{ Authorization = "Bearer $token" }
$uri     = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.HybridCompute/machines?api-version=2022-12-27"

$result = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET

$AzureArcInventory = $result.value | ForEach-Object {
    [PSCustomObject]@{
        ComputerName  = ($_.properties.osProfile.computerName -split '\.')[0].ToLower()
        ArcName       = $_.name
        ResourceGroup = $_.resourceGroup
        Location      = $_.location
        ArcId         = $_.id
        Source        = "AzureArc"
    }
}

# ============================================================
# 5. Indexera inventeringar
# ============================================================
$ADIndex  = $ADInventory        | Group-Object -Property ComputerName -AsHashTable
$VMIndex  = $AzureVMInventory   | Group-Object -Property ComputerName -AsHashTable
$ArcIndex = $AzureArcInventory  | Group-Object -Property ComputerName -AsHashTable

# ============================================================
# Funktioner
# ============================================================

function Get-OUFromDN {
    param([string]$dn)

    # Exempel: "CN=SRV01,OU=Servers,OU=Prod,DC=domain,DC=local"
    # Returnerar: "OU=Servers/OU=Prod"
    $parts = $dn -split ","
    $ous = $parts | Where-Object { $_ -like "OU=*" }
    return ($ous -join "/")
}

function Infer-ResourceTypeFromOU {
    param([string]$ou)

    # Anpassa reglerna efter er AD-struktur
    if ($ou -match "Arc") { return "AzureArc" }
    if ($ou -match "VM" -or $ou -match "HyperV" -or $ou -match "Compute") { return "AzureVM" }

    return "None"
}

# ============================================================
# 6. MissingInAzure – OU används för att gissa ResourceType
# ============================================================

$MissingInAzure = foreach ($name in $ADIndex.Keys) {
    if (-not $VMIndex.ContainsKey($name) -and -not $ArcIndex.ContainsKey($name)) {

        $ou = Get-OUFromDN -dn $ADIndex[$name].DistinguishedName
        $resourceType = Infer-ResourceTypeFromOU -ou $ou

        [PSCustomObject]@{
            Customer      = $CustomerName
            ComputerName  = $name
            ResourceType  = $resourceType
            Issue         = "MissingInAzure"
            TimeGenerated = (Get-Date)
        }
    }
}

# ============================================================
# 7. Matched – ResourceType baserat på AzureVM/AzureArc
# ============================================================

$Matched = foreach ($name in $ADIndex.Keys) {

    $resourceType = if ($VMIndex.ContainsKey($name)) {
        "AzureVM"
    } elseif ($ArcIndex.ContainsKey($name)) {
        "AzureArc"
    } else {
        continue
    }

    [PSCustomObject]@{
        Customer      = $CustomerName
        ComputerName  = $name
        ResourceType  = $resourceType
        Issue         = "OK"
        TimeGenerated = (Get-Date)
    }
}

# ============================================================
# 8. NoHeartbeat – ärver ResourceType från Matched
# ============================================================

$HBIndex = @{}
foreach ($h in $heartbeatClean) {
    $HBIndex[$h.Computer] = $h.TimeGenerated
}

$NoHeartbeat = foreach ($m in $Matched) {
    if (-not $HBIndex.ContainsKey($m.ComputerName)) {

        [PSCustomObject]@{
            Customer      = $CustomerName
            ComputerName  = $m.ComputerName
            ResourceType  = $m.ResourceType
            Issue         = "NoHeartbeat"
            TimeGenerated = (Get-Date)
        }
    }
}

$Matched = $Matched | Where-Object {
    $_.ComputerName -notin $NoHeartbeat.ComputerName
}

# ============================================================
# 9. Output och Skicka till log analytics
# ============================================================
#fyll i dessa variablers med korrekt värden
#ClientID= App id i appen
$ClientId="<Insert app registration clientID here>"
#Client secret= Secret value för appen
$ClientSecret="<Insert app registration secret here>"
#TenantId= Directory ID som syns i appen
$TenantId="<Insert app registration tenantID here>"
#set context till tenant så vi inte är kvar i kundens subscription
Set-AzContext -tenant $TenantId

#Logs ingestion endpoint i Data collection endpointet
$Endpoint="<Insert data collection endpoint here>"


#DCR IMMUTABLE ID
$DCRID="<Insert DCR immutableID here here>"

#Hittas i JSON view av DCRet "outputStream"
$Stream ="<Insert DCR output stream here>"

$scope = [System.Web.HttpUtility]::UrlEncode("https://monitor.azure.com//.default")   
$body = "client_id=$ClientId&scope=$scope&client_secret=$ClientSecret&grant_type=client_credentials";
$headers = @{"Content-Type" = "application/x-www-form-urlencoded" };
$uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$bearerToken = (Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers).access_token
$headersPOST = @{
    "Authorization" = "Bearer $bearerToken"
    "Content-Type"  = "application/json"
}
 
#Var ska det skickas
$api = "?api-version=2023-01-01"
$uriPOST = "$Endpoint/dataCollectionRules/$DCRID/streams/$Stream$api"

#alt 2
#$uriPOST2 = "{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01" -f $Endpoint, $DCRID, $Stream

#funktioner för att se till att det vi skickar är en array även om det är ett objekt
# samt funktion för att checka att det inte är tomt (null)
function Is-Empty {
    param($obj)

    if ($null -eq $obj) { return $true }
    if ($obj -is [System.Collections.IEnumerable] -and $obj.Count -eq 0) { return $true }

    return $false
}
function Ensure-ArrayJson {
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    # Om objektet är $null → returnera tom array
    if ($null -eq $InputObject) {
        return "[]"
    }

    # Om det redan är en array → konvertera direkt
    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject.GetType().Name -ne 'String') {

        return ($InputObject | ConvertTo-Json -Depth 10)
    }

    # Annars: gör om det till en array med ett element
    return @($InputObject) | ConvertTo-Json -Depth 10
}

Write-Output "===== MATCHED (FULLA OBJEKT) ====="

$matchedJSON = $Matched | ConvertTo-Json -Depth 10

$matchedJSON
$response = Invoke-RestMethod -Method Post -Uri $uriPOST -Headers $headersPOST -Body $matchedJSON

Write-Output "===== MISSING IN AZURE ====="
$MissingInAzure


if (-not (Is-Empty $MissingInAzure)) {
    $missingJSON = Ensure-ArrayJson -InputObject $MissingInAzure
    $missingJSON

    $response = Invoke-RestMethod -Method Post -Uri $uriPOST -Headers $headersPOST -Body $missingJSON
}
else {
    Write-Output "Skipping MissingInAzure – no data to send."
}

# ============================
# NO HEARTBEAT
# ============================
Write-Output "===== NO HEARTBEAT ====="
$NoHeartbeat

if (-not (Is-Empty $NoHeartbeat)) {
    $heartbeatJSON = Ensure-ArrayJson -InputObject $NoHeartbeat
    $heartbeatJSON

    $response = Invoke-RestMethod -Method Post -Uri $uriPOST -Headers $headersPOST -Body $heartbeatJSON
}
else {
    Write-Output "Skipping NoHeartbeat – no data to send."
}
