﻿<#
    .SYNOPSIS
        Distribute-Groups.ps1 collects the members from any number of AD groups and distributes them equally to any number of target AD groups 
    .DESCRIPTION
        This Script can used within a schedul to dynamically distribute equally AD Group Members to a bunch of AD Groups.
        We used this to distribute the VDI-Users to several Horizon Desktop-Pools  
    .NOTES
        © tempero.it GmbH
        Klaus Kupferschnmid
        Version 1.0 2020-12-01
    .COMPONENT
        Requires Module ActiveDirectory (Import-Module ActiveDirectory)
        Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
    .LINK
        \\ws16-auto.universe.hhp\c$\Scripts\UserManager.ps1
#>

# Input Variables
$sourceGroupNameArray = @('vdi_intern','vdi_extern')
$destinationGroupNameArray =@('vdiPool_RZ','vdiPool_BRZ') 

# Read Members from AD-Groups
# Read Source Groups
$sourceGroupMembers       = @()
foreach ($sourceGroupName in $sourceGroupNameArray) {
    if(Get-ADGroup -Identity $sourceGroupName) {
        $sourceGroupMembers      += (Get-ADGroupMember $sourceGroupName).SamAccountName
    } else {
        Write-Host "AD-Gruppe '"$sourceGroupName"' existiert nicht - ABBRUCH!" -ForegroundColor 'Red'
        Exit
    }
}
# Read Destination Groups
$destinationGroups = @()
$destinationGroupMembers  = @()
foreach ($destinationGroupName in $destinationGroupNameArray) {
    if(Get-ADGroup -Identity $destinationGroupName) {
        $members = (Get-ADGroupMember $destinationGroupName).SamAccountName
        
        $destinationGroup = New-Object System.Object
        $destinationGroup | Add-Member -type NoteProperty -name Name -value $destinationGroupName
        $destinationGroup | Add-Member -type NoteProperty -name MemberCount -Value $members.count
        $destinationGroups += $destinationGroup
        foreach ($member in $members){
            $destinationGroupMember = New-Object System.Object
            $destinationGroupMember | Add-Member -type NoteProperty -name DestinationGroupName -value $destinationGroupName
            $destinationGroupMember | Add-Member -type NoteProperty -name SamAccountName -value $member
            $destinationGroupMembers += $destinationGroupMember
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
$removedMembers = ($noStockMembers | Where-Object SideIndicator -eq '<=').InputObject
}
else {
    $newMembers = $sourceGroupMembers
}

# remove Members in DestinationGroups
$newDestinationGroupMembers = @()
foreach ($destinationGroupMember in $destinationGroupMembers ) {
    if ($destinationGroupMember.SamAccountName -contains  $removedMembers ){
        Write-Host "Aus der AD-Gruppe '"$destinationGroupMember.DestinationGroupName"' wird das Gruppen-Mitglied '"$destinationGroupMember.SamAccountName"' gelöscht." -ForegroundColor Green
        try {
            Remove-ADGroupMember -Identity $destinationGroupMember.DestinationGroupName -Members $destinationGroupMember.SamAccountName -confirm:$false #-WhatIf
        }
        catch {
            Write-Host $error.Exception.Message "- ABBRUCH!" -ForegroundColor Red
            Exit
        }
        $destinationGroups | ForEach-Object -Process {if ($_.Name -eq $destinationGroupMember.DestinationGroupName) { $_.MemberCount = $_.MemberCount -1}}
    }
    else {
        $newDestinationGroupMembers += $destinationGroupMember
    }
}

# Add the new Member to the respective smallest group
Foreach ($newMember in $newMembers){
    $smallestGroupName = ($destinationGroups | Sort-Object -Property MemberCount | Select-Object -first 1).Name
    Write-Host "Gruppen-Mitglied '"$newMember"' wird zur AD-Gruppe '"$smallestGroupName"' hinzugefügt." -ForegroundColor Green
    try {
        Add-ADGroupMember -Identity $smallestGroupName -Members $newMember #-WhatIf
    }
    catch {
        Write-Host $error.Exception.Message "- ABBRUCH!" -ForegroundColor Red
        Exit
    }
    $destinationGroups | ForEach-Object -Process {if ($_.Name -eq $smallestGroupName) { $_.MemberCount = $_.MemberCount +1}}
    $destinationGroupMember = New-Object System.Object
    $destinationGroupMember | Add-Member -type NoteProperty -name DestinationGroupName -value $smallestGroupName
    $destinationGroupMember | Add-Member -type NoteProperty -name SamAccountName -value $newMember
    $newDestinationGroupMembers += $destinationGroupMember
}
    
# Output Destination-Groups
$newDestinationGroupMembers | Format-Table 
$destinationGroups | Format-Table