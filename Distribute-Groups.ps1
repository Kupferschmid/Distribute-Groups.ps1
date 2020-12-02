<#
    .SYNOPSIS
        Distribute-Groups.ps1 collects the members from any number of AD groups and distributes them equally to any number of target AD groups. 
    .DESCRIPTION
        This script can be used within a schedule to dynamically distribute members of AD groups evenly across a number of AD groups.
        We have used this script to distribute VDI users across multiple Horizon desktop pools.   
    .NOTES
        © tempero.it GmbH
        Klaus Kupferschnmid
        Version 1.2 2020-12-02
    .COMPONENT
        Requires Module ActiveDirectory (Import-Module ActiveDirectory)
        Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
    .LINK
        https://github.com/Kupferschmid/Distribute-Groups.ps1
#>

# Input Variables
$sourceGroupNameArray = @('vdi_intern','vdi_extern')
$destinationGroupNameArray =@('vdiPool_RZ','vdiPool_BRZ') 

function Remove-DestinationGroupMembers { # remove Members in DestinationGroups
    Param
    (
        [parameter(Position=0,Mandatory=$true,ValueFromPipeline)]$groupName,
        [parameter(Position=1,Mandatory=$false,ValueFromPipeline)]$member
    )    
        Write-Host "Aus der AD-Gruppe '"$groupName"' wird das Gruppen-Mitglied '"$member"' gelöscht." -ForegroundColor Green
        $error.clear()
        try {
            Remove-ADGroupMember -Identity $groupName -Members $member -confirm:$false #-WhatIf
        }
        catch {
            Write-Host $error.Exception.Message "- ABBRUCH!" -ForegroundColor Red
            $error.clear()
            Exit
        }
        $destinationGroups | ForEach-Object -Process {if ($_.Name -eq $groupName) { $_.MemberCount = $_.MemberCount -1}}
}

function Add-DestinationGroupMembers { #Add Member to Destination Group
    Param
    (
        [parameter(Position=0,Mandatory=$true,ValueFromPipeline)]$groupName,
        [parameter(Position=1,Mandatory=$true,ValueFromPipeline)]$member
    ) 
    Write-Host "Gruppen-Mitglied '"$member"' wird zur AD-Gruppe '"$groupName"' hinzugefügt." -ForegroundColor Green
    $error.clear()
    try {
        Add-ADGroupMember -Identity $groupName -Members $member #-WhatIf
    }
    catch {
        Write-Host $error.Exception.Message "- ABBRUCH!" -ForegroundColor Red
        $error.clear()
        Exit
    }
    $destinationGroups | ForEach-Object -Process {if ($_.Name -eq $groupName) { $_.MemberCount = $_.MemberCount +1}}
    $destinationGroupMember = New-Object System.Object
    $destinationGroupMember | Add-Member -type NoteProperty -name DestinationGroupName -value $groupName
    $destinationGroupMember | Add-Member -type NoteProperty -name SamAccountName -value $member
    $newDestinationGroupMembers += $destinationGroupMember
    return $newDestinationGroupMembers
}

# Declare Object-Arrays
$sourceGroupMembers = @()
$script:destinationGroups = @()
$destinationGroupMembers  = @()
$newDestinationGroupMembers = @()
$error.clear()

# Read Members from AD-Groups
# Read Source Groups
foreach ($sourceGroupName in $sourceGroupNameArray) {
    if(Get-ADGroup -Identity $sourceGroupName) {
        $members = (Get-ADGroupMember $sourceGroupName).SamAccountName
        if ($members) {
            $sourceGroupMembers += $members
        }
    } else {
        Write-Host "AD-Gruppe '"$sourceGroupName"' existiert nicht - ABBRUCH!" -ForegroundColor 'Red'
        Exit
    }
}

# Read Destination Groups
foreach ($destinationGroupName in $destinationGroupNameArray) {
    if(Get-ADGroup -Identity $destinationGroupName) {
        $members = (Get-ADGroupMember $destinationGroupName).SamAccountName
        $destinationGroup = New-Object System.Object
        $destinationGroup | Add-Member -type NoteProperty -name Name -value $destinationGroupName
        $destinationGroup | Add-Member -type NoteProperty -name MemberCount -Value $members.count
        $destinationGroups += $destinationGroup
        if ($members) {
            foreach ($member in $members){
                $destinationGroupMember = New-Object System.Object
                $destinationGroupMember | Add-Member -type NoteProperty -name DestinationGroupName -value $destinationGroupName
                $destinationGroupMember | Add-Member -type NoteProperty -name SamAccountName -value $member
                $destinationGroupMembers += $destinationGroupMember
            }
        }
        else {
            $destinationGroupMember = $null
        }
    } else {
        Write-Host "AD-Gruppe '"$destinationGroupName"' existiert nicht - ABBRUCH!" -ForegroundColor 'Red'
        Exit
    }  
}

# Compare Groups to find out new and removed Members
if ($destinationGroupMembers.count -gt 0)
{
$noStockMembers = Compare-Object  $destinationGroupMembers.SamAccountName $sourceGroupMembers
$newMembers = ($noStockMembers | Where-Object SideIndicator -eq '=>').InputObject
$removeMembers = ($noStockMembers | Where-Object SideIndicator -eq '<=').InputObject
} else {
    $newMembers = $sourceGroupMembers
    $noStockMembers = $null
    $removeMembers = $null
}

# remove Members in DestinationGroups
foreach ($destinationGroupMember in $destinationGroupMembers ) {
    if ( $removeMembers -contains $destinationGroupMember.SamAccountName ){
        Remove-DestinationGroupMembers -GroupName $destinationGroupMember.DestinationGroupName -Member $destinationGroupMember.SamAccountName
    } else {
        $newDestinationGroupMembers += $destinationGroupMember
    }
}

# Add the new Member to the respective smallest group
Foreach ($newMember in $newMembers){
    $smallestGroupName = ($destinationGroups | Sort-Object -Property MemberCount | Select-Object -first 1).Name
    $newDestinationGroupMembers += Add-DestinationGroupMembers -GroupName $smallestGroupName -Member $newMember
}

# check balance of Destination Groups
do {
    $measure = $destinationGroups | Measure-Object -Property MemberCount -Maximum -Minimum 
    If (($measure.Maximum - $measure.Minimum) -gt 1){
        $largestGroupName = ($destinationGroups | Sort-Object -Property MemberCount | Select-Object -last 1).Name
        $smallestGroupName = ($destinationGroups | Sort-Object -Property MemberCount | Select-Object -first 1).Name
        $moveMember = ($newDestinationGroupMembers | Where-Object {$_.DestinationGroupName -eq $largestGroupName} | Select-Object -first 1).SamAccountName
        Write-Host "Gruppen-Mitglied '"$moveMember "' muss von der AD-Gruppe '"$largestGroupName"' zur AD-Gruppe '"$smallestGroupName"' verschoben werden." -ForegroundColor Green
        Remove-DestinationGroupMembers -GroupName $largestGroupName -Member $moveMember
        $destinationGroupMembers = $newDestinationGroupMembers
        $newDestinationGroupMembers = @() # Reset Array to refil only with valid Objects
        foreach ($destinationGroupMember in $destinationGroupMembers) {
            if ($destinationGroupMember.SamAccountName -eq $moveMember) {
                #do nothing to remove Object from Array
            } else {
                $newDestinationGroupMembers += $destinationGroupMember 
            }
        }
        $destinationGroupMembers = $newDestinationGroupMembers
        $newDestinationGroupMembers = Add-DestinationGroupMembers -GroupName $smallestGroupName -Member $moveMember  
    }
}until (($measure.Maximum - $measure.Minimum) -le 1) 

# Output Destination-Groups
$newDestinationGroupMembers | Format-Table 
$destinationGroups | Format-Table