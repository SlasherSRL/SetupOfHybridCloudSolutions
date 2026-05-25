Connect-AzAccount -Identity
Import-Module ActiveDirectory

$servers = Get-ADComputer -Filter * -Properties OperatingSystem,Enabled,DistinguishedName |
    Where-Object {
        $_.Enabled -eq $true -and
        $_.OperatingSystem -like "*Server*" -and
        $_.OperatingSystem -notmatch "2012"
    }




$results = foreach ($s in $servers) {
    [PSCustomObject]@{
        ComputerName      = $s.Name
        OperatingSystem   = $s.OperatingSystem
        DistinguishedName = $s.DistinguishedName
        Source            = "ActiveDirectory"
        Enabled = $s.Enabled
    }
}

$results | ConvertTo-Json -Depth 10
