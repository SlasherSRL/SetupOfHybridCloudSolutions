

# ============================================================
# 0. Autentisering och kontext
# ============================================================
Connect-AzAccount -Identity

$subs = Get-AzSubscription
Write-Output "Found $($subs.Count) subscriptions in scope."

function Get-ResourceGroupFromId {
    param([string]$Id)

    $parts = $Id -split '/'
    $index = $parts.IndexOf('resourceGroups')
    if ($index -ge 0 -and $parts.Length -gt $index + 1) {
        return $parts[$index + 1]
    }
    return $null
}


$allVMs= @()
$allARCs= @()
$maintenanceConfigs = @()
foreach ($sub in $subs) {
    Write-Output "  Subscription: $($sub.Name) [$($sub.Id)]"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    try {
        $configs = Get-AzMaintenanceConfiguration -ErrorAction Stop
    }
    catch {
        Write-Warning "    Failed to get maintenance configurations in subscription $($sub.Id): $_"
        continue
    }
    #$configs
    $VMs= Get-AzVM -Status | ForEach-Object {
        [PSCustomObject]@{
            ComputerName  = ($_.OsProfile.ComputerName -split '\.')[0].ToLower()
            Name        = $_.Name
            SubscriptionId   = $sub
            ResourceGroup = $_.ResourceGroupName
            Location      = $_.Location
            VmId          = $_.VmId
            ResourceType   = "AzureVM"
            ProviderName   = "Microsoft.Compute"
            ResourceTypeName = "virtualMachines"
        }
    }
    $allVMs+=$VMs

    $token   = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{ Authorization = "Bearer $token" }
    $uri     = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.HybridCompute/machines?api-version=2022-12-27"

    $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET

   
    $AzureArcInventory = $result.value | ForEach-Object {
         $rg = Get-ResourceGroupFromId $_.id

        [PSCustomObject]@{
            ComputerName  = ($_.properties.osProfile.computerName -split '\.')[0].ToLower()
            Name       = $_.name
            SubscriptionId   = $sub
            ResourceGroup = $rg
            Location      = $_.location
            ArcId         = $_.id
            Source        = "AzureArc"
            ResourceType     = "ArcServer"
            ProviderName     = "Microsoft.HybridCompute"
            ResourceTypeName = "machines"
            
        }
    }
    $allARCs += $AzureArcInventory
    foreach ($cfg in $configs) {

             $maintenanceConfigs+= [PSCustomObject]@{
            SubscriptionId        = $sub.Id
            ResourceGroupName     = $cfg.ResourceGroupName
            Name                  = $cfg.Name
            Location              = $cfg.Location
            MaintenanceScope      = $cfg.MaintenanceScope
            StartDateTime         = $cfg.StartDateTime
            ExpirationDateTime    = $cfg.ExpirationDateTime
            Duration              = $cfg.Duration
            TimeZone              = $cfg.TimeZone
            Properties            = $cfg
        }
    }
   
}

Write-Output "Found $($maintenanceConfigs.Count)  maintenance configurations."
#$maintenanceConfigs
$allARCs.Count
$allVMs.Count
$allServers = $allVMs+ $allARCs

<#
function Get-PeriodicAssessmentStatus {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$ProviderName,
        [string]$ResourceTypeName,
        [string]$ResourceName
    )

    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{ Authorization = "Bearer $token" }

    # Build the base resource path
    $baseId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/$ProviderName/$ResourceTypeName/$ResourceName"

    # Correct Update Manager endpoint
    $uri = "https://management.azure.com$baseId/providers/Microsoft.Maintenance/updateStatus?api-version=2023-09-01-preview"

    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET 

        # If assessmentStatus exists → periodic assessment is enabled
        if ($result.assessmentStatus -and $result.assessmentStatus.lastAssessmentTime) {
            return $true
        }

        return $false
    }
    catch {
        # If the machine is not onboarded or not accessible, treat as false
         Write-Output "ERROR for $ResourceName"
         Write-Output $_.Exception.Message
        return $false
    }
}
#>

$report = @()
foreach ($m in $allServers) {
    #Write-Output "  Machine: $($m.Name) [$($m.ResourceType)]"
    #Write-Output "ARC: $($m.Name) RG='$($m.ResourceGroup)'"

    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{
        Authorization = "Bearer $token"
    }
    $subId = $m.SubscriptionId
    $resGroup = $m.ResourceGroup
    $ProvName = $m.ProviderName
    $ResTypeName= $m.ResourceTypeName
    $ResName = $m.Name
    $baseId = "/subscriptions/$subId/resourcegroups/$resGroup/providers/$ProvName/$ResTypeName/$ResName"
    $uri2 = "https://management.azure.com$baseId/providers/Microsoft.Maintenance/configurationAssignments?api-version=2023-09-01-preview"

   
    $result = Invoke-RestMethod -Uri $uri2 -Headers $headers -Method GET 
    $assignments = $result.value
    
<#
    $periodic = Get-PeriodicAssessmentStatus `
    -SubscriptionId $m.SubscriptionId `
    -ResourceGroup $m.ResourceGroup `
    -ProviderName $m.ProviderName `
    -ResourceTypeName $m.ResourceTypeName `
    -ResourceName $m.Name
    $periodic
#>
    if ($assignments.Count -eq 0) {
        $report += [PSCustomObject]@{
            SubscriptionId             = $m.SubscriptionId
            ResourceGroup              = $m.ResourceGroup
            MachineName                = $m.Name
            ResourceType               = $m.ResourceType
            Location                   = $m.Location
            OsType                     = $m.OsType
            ProviderName               = $m.ProviderName
            ResourceTypeName           = $m.ResourceTypeName
            HasConfigurationAssignment = $false
            ConfigurationAssignmentNames = ""
            MaintenanceConfigurationIds  = ""
           # PeriodicAssessmentEnabled = $periodic
        }
    }
    else {
        $names = @()
        $mcIds = @()

        foreach ($a in $assignments) {
            $names += $a.name
            $mcIds += $a.properties.maintenanceConfigurationId
        }

        $report += [PSCustomObject]@{
            SubscriptionId               = $m.SubscriptionId
            ResourceGroup                = $m.ResourceGroup
            MachineName                  = $m.Name
            ResourceType                 = $m.ResourceType
            Location                     = $m.Location
            OsType                       = $m.OsType
            ProviderName                 = $m.ProviderName
            ResourceTypeName             = $m.ResourceTypeName
            HasConfigurationAssignment   = $true
            ConfigurationAssignmentNames = ($names -join "; ")
            MaintenanceConfigurationIds  = ($mcIds -join "; ")
           # PeriodicAssessmentEnabled = $periodic
        }
    }
}
Write-Output "Report rows: $($report.Count)"

#$report | Format-Table -AutoSize

#---------
# Jämför med inventering
#---------
Set-AzContext -Subscription "f4a3cfcf-912c-4562-bbca-d1ffaa0f4730" | Out-Null
$WorkspaceRG       = "RG-monitor"
$WorkspaceName     = "LOG-monitor"
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $WorkspaceRG `
    -Name $WorkspaceName

#Se till att denna är korrekt log
$query = @"
InventoryStatusLog_CL
| where TimeGenerated > ago(24h)
| where Issue == "NoHeartbeat" or Issue =="OK"
|project  Customer,ComputerName,TimeGenerated,Issue,ResourceType
"@

$logQuery = Invoke-AzOperationalInsightsQuery `
    -WorkspaceId $workspace.CustomerId `
    -Query $query

$InventoryStatus = $logQuery.Results | ForEach-Object {
    [PSCustomObject]@{
        Customer      = $_.Customer
        ComputerName  = $_.ComputerName
        TimeGenerated = $_.TimeGenerated
        Issue         = $_.Issue
        ResourceType  = $_.ResourceType
    }
}

$Overlap = $InventoryStatus |
    Where-Object { $_.ComputerName -in $report.MachineName }


$MergedOverlap = foreach ($inv in $Overlap) {
    $um = $report | Where-Object { $_.MachineName -eq $inv.ComputerName }

    [PSCustomObject]@{
        Customer                     = $inv.Customer
        ComputerName                 = $inv.ComputerName
        ResourceType                 = $inv.ResourceType
        Issue = "OK"
        TimeGenerated                =(Get-Date)
        # From Update Manager report
        HasConfigurationAssignment   = $um.HasConfigurationAssignment
        ConfigurationAssignmentNames = $um.ConfigurationAssignmentNames
    }
}

$NotInMachines = $InventoryStatus |
    Where-Object { $_.ComputerName -notin $report.MachineName }


$NotInMachines = foreach ($inv in $NotInMachines) {
    

    [PSCustomObject]@{
        Customer                     = $inv.Customer
        ComputerName                 = $inv.ComputerName
        ResourceType                 = $inv.ResourceType
        Issue = "Missing in Azure Update Machines"
        TimeGenerated                = (Get-Date)
        HasConfigurationAssignment   = $um.HasConfigurationAssignment
        ConfigurationAssignmentNames = $um.ConfigurationAssignmentNames

    }
}


#------
Write-Output "-------- NOT IN MACHINES --------"
$NotInMachines | Format-Table -AutoSize


#Send to a log table. implement after everything works
# ============================================================
# x. Output och Skicka till log analytics
# ============================================================
#fyll i dessa variablers med korrekt värden
#ClientID= App id i appen
$ClientId=""
#Client secret= Secret value för appen
$ClientSecret=""
#TenantId= Directory ID som syns i appen
$TenantId=""
#set context till tenant så vi inte är kvar i kundens subscription
Set-AzContext -tenant $TenantId

#Logs ingestion endpoint i Data collection endpointet
$Endpoint=""



#DCR IMMUTABLE ID
$DCRID=""

#Hittas i JSON view av DCRet "outputStream"
$Stream =""

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

Write-Output "===== Overlap ====="
    $overlapJSON = Ensure-ArrayJson -InputObject $MergedOverlap
    $overlapJSON
    
     $response1 = Invoke-RestMethod -Method Post -Uri $uriPOST -Headers $headersPOST -Body $overlapJSON
Write-Output "===== MISSING IN MACHINES ====="


if (-not (Is-Empty $NotInMachines)) {
    $missingJSON = Ensure-ArrayJson -InputObject $NotInMachines
    $missingJSON

    $response2 = Invoke-RestMethod -Method Post -Uri $uriPOST -Headers $headersPOST -Body $missingJSON
}
else {
    Write-Output "Skipping missing update, none missing"
}
