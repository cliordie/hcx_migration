# HCX Migration Tool
# Tucker Hewitt, 2020

Import-Module VMware.PowerCLI

## Global Variables

$domain = "hospital.org"
$vcenters = @("sourcevcenter1.hospital.org", "sourcevcenter2.hospital.org","destvcenter1.hospital.org","destvcenter2.hospital.org")
# Migration Window in Hours
$migwindow = 8

## Log Function

$DirInfo = Get-Location
$WorkingDir = $DirInfo.Path
$FileDate = Get-Date -Format "MM-dd-yy hh-mm"
$LogFile = "$WorkingDir\HCX_Migrations_$FileDate.log"
New-Item -Path $LogFile -ItemType File -Force

function write-mylog {
    param (
    [Parameter(mandatory=$true)][string]$logdata
    )

    $TimeStamp = Get-Date -Format "MM/dd/yy HH:mm:ss"
    Add-Content -Path $LogFile -Value "$TimeStamp | $LogData"
    Write-Output "$TimeStamp | $LogData"
}

## Words
Clear-Host
Write-Output "--- HCX Migration Tool ---"
Write-Output "This script uses the hcx_migration.csv"
Write-Output "to build and schedule migration jobs"
Write-Output ""
write-mylog "Importing CSV..."
$migdata = Import-csv "./hcx_migration.csv"
$lasthcxmgr = ""
Write-Output ""
Write-Output "Please enter your credentials"
$creds = Get-Credential
Write-Output ""

## Connect to vCenters
Foreach ($vcenteritem in $vcenters) {
    write-mylog "Connecting to $vcenteritem"
    $Trash = Connect-VIServer -Server $vcenteritem -Credential $creds
}

Foreach ($migline in $migdata) {

    $ercode = 0
    $finalcode = ""

    ## Determine Host's Home vCenter and Network from current vCenter
    $mignm = $migline.VMName
    write-mylog "----- Building Migration for $mignm -----"
    $testprod = $migline.Test_Prod
    $MigDate = $migline.MigrationDate
    $MigTime = $migline.MigrationTime
    $MigSchedule = "$MigDate $MigTime"
    $StartTime = [Datetime]$MigSchedule
    $EndTime = $StartTime.AddHours($migwindow)

    If ($mignm -eq "") {
        $ercode = 1
        write-mylog "No VM Specified"
        
    } elseif ($testprod -eq "" ){
        $ercode = 1
        write-mylog "No Server Type Specified (PROD/TEST)"
    } elseif ($MigDate -eq "") { 
        $ercode = 1
        write-mylog "No Migration Date Specified"        
    } elseif ($MigTime -eq "") {
        $ercode = 1
        write-mylog "No Migration Time Specified"
    }
    If ($ercode -eq 0) {
        ## Gather VM Information
        write-mylog "Getting VM Information for $mignm"

        ## Get VM Cluster Location
        Try {
            $VMClusterData = Get-VM "$mignm" | Get-Cluster
        } Catch {
            write-mylog "Unable to Locate $mignm in any vCenter" 
            $finalcode = "We were unable to locate $mignm in any connected vCenter $_.ErrorDetails"
            $ercode = 1
        }
        $VMCluster = $VMClusterData.Name
    }
    ## Get VM Network Data
    If ($ercode -eq 0){
        $VMNetworks = New-Object System.Data.DataTable "VMNetworks"
        $col1 = New-Object System.Data.DataColumn "NetworkName"
        $col2 = New-Object System.Data.DataColumn "vlanID"
        $col3 = New-Object System.Data.DataColumn "ID"
        $VMNetworks.Columns.Add($col1)
        $VMNetworks.Columns.Add($col2)
        $VMNetworks.Columns.Add($col3)

        Try {
            $VMNetworkData = Get-VM "$mignm" | Get-NetworkAdapter
        } Catch {
            write-mylog "Unable to obtain network data from $mignm"
            $finalcode = "We were unable to gather current network Data from $mignm $_.ErrorDetails"
            $ercode = 1
        }
        Foreach ($VMNetwork in $VMNetworkData){
            $VMNetworkName = $VMNetwork.NetworkName
            Try {
                $Result = Get-Cluster -Name "$VMCluster" | Get-VMHost | Get-VirtualPortGroup | Where-Object {$_.name -eq "$VMNetworkName"} | Select-Object *
            } Catch {
                write-mylog "Unable to Locate Network Data for $VMNetworkName on $VMCluster $_.ErrorDetails"
                $ercode = 1
            }
            $ResId = $Result.ID
            $pvid = $ResId.Substring(28)
            $row = $VMNetworks.NewRow()
            $row.NetworkName = $VMNetworkName
            $row.vlanID = $Result.ExtensionData.Config.DefaultPortConfig.Vlan.vlanID
            $row.ID = $pvid
            $VMNetworks.Rows.Add($row)
        }
    }

    ## Get vCenter Information
    If ($ercode -eq 0) {
        $VMvCenterInfo = Get-VM -Name $mignm | % {[PSCustomObject] @{
            Name = $_.Name
            vCenter = $_.Uid.Substring($_.Uid.IndexOf('@')+1).Split(":")[0]
            }
        }
        $VMvCenter = $VMvCenterInfo.vCenter
    }
    
    ## Determine Placement Params
    If ($ercode -eq 0) {
        write-mylog "Determining Placement"    
        If ($VMvCenter -eq "sourcevcenter1.hospital.org") {
            $hcxmanager = "hcxmanager1.$domain"

            If ($VMCluster -eq "sourcevsanCluster1" -or $VMCluster -eq "sourcevsanCluster2" -or $VMCluster -eq "sourcevSanCluster3" -or $VMCluster -eq "sourcevSanCluster4") {
                $DestinationSite = "destvcenter2.$domain"
                $DestinationContainer = "HCX Migrations"
                $DestinationCluster = "dvc2-cluster1"
                $DestinationStorage = "dvc2-cluster1-vsan"
                $DestinationProvisioning = "Thin"

            } elseif ($VMCluster -eq "sourcecluster1" -or $VMCluster -eq "sourcecluster2" -or $VMCluster -eq "sourcecluster3" ) {
                $DestinationSite = "destvcenter1.$domain"
                $DestinationContainer = "HCX Migrations"
                $DestinationCluster = "destCluster1"
                $DestinationProvisioning = "SameAsSource"
                If ($testprod -eq "PROD" -or $testprod -eq "prod") {
                    $DestinationStorage = "dc1-dsc-prod"
                } else {
                    $DestinationStorage = "dc1-dsc-dev"
                }

            } elseif ($VMCluster -eq "sourceCluster4") {
                $DestinationSite = "destvcenter1.$domain"
                $DestinationContainer = "HCX Migrations"
                $DestinationCluster = "destCluster2"
                $DestinationProvisioning = "SameAsSource"
                If ($testprod -eq "PROD" -or $testprod -eq "prod") {
                    $DestinationStorage = "dc2-dsc-prod"
                } else {
                    $DestinationStorage = "dc2-dsc-dev"
                }

            } elseif ($VMCluster -eq "sourceCluster5") {
                $DestinationSite = "destvcenter1.$domain"
                $DestinationContainer = "HCX Migrations"
                $DestinationCluster = "destcluster3"
                $DestinationProvisioning = "SameAsSource"
                If ($testprod -eq "PROD" -or $testprod -eq "prod") {
                    $DestinationStorage = "dc3-dsc-prod"
                } else {
                    $DestinationStorage = "dc3-dsc-dev"
                }

            } elseif ($VMCluster -eq "sourceCluster6") {
                $DestinationSite = "destvcenter1.$domain"
                $DestinationContainer = "HCX Migrations"
                $DestinationCluster = "destcluster4"
                $DestinationProvisioning = "SameAsSource"
                If ($testprod -eq "PROD" -or $testprod -eq "prod") {
                    $DestinationStorage = "dc4-dsc-prod"
                } else {
                    $DestinationStorage = "dc4-dsc-dev"
                }
            }


        } elseif ($VMvCenter -eq "sourcevcenter2.hospital.org") {
            $hcxmanager = "hcxmanager2.$domain"       
            $DestinationSite = "destvcenter1.$domain"
            $DestinationContainer = "HCX Migrations"
            $DestinationCluster = "Cluster1"
            $DestinationProvisioning = "SameAsSource"
            If ($testprod -eq "PROD" -or $testprod -eq "prod") {
                $DestinationStorage = "dc1-dsc-prod"
            } else {
                $DestinationStorage = "dc1-dsc-dev"
            }
        }

        write-mylog "Current Site: $VMvCenter"
        write-mylog "Current Cluster: $VMCluster"
        Foreach ($netline in $VMNetworks) {
            $netname = $netline.NetworkName
            $netvid = $netline.vlanID
            write-mylog "Current Network: $netname"
            write-mylog "Current VLAN: $netvid " 
        }
        write-mylog "Destination Site: $DestinationSite "
        write-mylog "Destination Cluster: $DestinationCluster"
        write-mylog "Destination Container: $DestinationContainer"
        write-mylog "Destination Storage: $DestinationStorage"

    
        ## Connect to HCX Manager
        If ($lasthcxmgr -ne $hcxmanager) {
        write-mylog "Connecting to HCX Server $hcxmanager"
        $Trash = Disconnect-HCXServer * -Force -Confirm:$false -ErrorAction SilentlyContinue
        $Trash = Connect-HCXServer -Server $hcxmanager -Credential $creds -ErrorAction Stop
        } else {
            write-mylog "$hcxmanager Already Connected. Skipping....."  
        }

        ## Setting Site Information
        Try {
            $SrcSite = Get-HCXSite -Source -ErrorAction Stop
            $DestSite = Get-HCXSite -Destination -name $DestinationSite -ErrorAction Stop
        } Catch {
            write-mylog "Unable to obtain site information from HCX $_.ErrorDetails"
            $ercode = 1

        }
    }
    ## Build Network Mappings
    If ($ercode -eq 0) {
        write-mylog "Building Network Mappings"
        $NetworkMappings = @()

        Foreach ($Network in $VMNetworks){
            $vnetname = $Network.NetworkName
            $vnetvlan = $Network.vlanID
            $vnetkey = $Network.ID
        
            Try {
                $SrcNet = Get-HCXNetwork -Name "$vnetname" -Site $SrcSite | Where-Object {$_.Id -eq $vnetkey}
                $SrcNetName = $SrcNet.Name

                If ($vnetname -eq "DMZvlan") {
                    $DestNet = Get-HCXNetwork -Site $DestSite | Where-Object {$_.Type -eq "OpaqueNetwork"} | Where-Object {$_.Name -like "*vlan-001"}
                } elseif ($vnetname -eq "vlan05"){
                    $DestNet = Get-HCXNetwork -Site $DestSite | Where-Object {$_.Type -eq "OpaqueNetwork"} | Where-Object {$_.Name -like "*vlan-002"}
                } elseif ($vnetname -eq "vlan06"){
                    $DestNet = Get-HCXNetwork -Site $DestSite | Where-Object {$_.Type -eq "OpaqueNetwork"} | Where-Object {$_.Name -like "*vlan-003"}
                } elseif ($vnetname -eq "vlan07"){
                    $DestNet = Get-HCXNetwork -Site $DestSite | Where-Object {$_.Type -eq "OpaqueNetwork"} | Where-Object {$_.Name -like "*vlan-004"}
                } else {
                    $DestNet = Get-HCXNetwork -Site $DestSite | Where-Object {$_.Type -eq "OpaqueNetwork"} | Where-Object {$_.Name -like "*vlan-$vnetvlan"}
                }

                $DestNetName = $DestNet.Name
                $NetworkMapping = New-HCXNetworkMapping -SourceNetwork $SrcNet -DestinationNetwork $DestNet
                $NetworkMappings += $NetworkMapping

            } Catch {
                $ercode = 1
                write-mylog "Unable to Build Network Mapping"
                $finalcode = "There was an issue building the network mapping. This could be caused by ambigous names or VLANS. $_.ErrorDetails"
            }
            write-mylog "Network Mapping $SrcNetName > $DestNetName"
        } 
    }

    ## Get Compute Information
    If ($ercode -eq 0) {
        write-mylog "Getting Compute Information"
        Try {
            $hcxvm = Get-HCXVM -Name $mignm -ErrorAction Stop
            $DestCompute = Get-HCXContainer -Name $DestinationCluster -Site $DestSite -Type "Cluster" -ErrorAction Stop
            $DestDataStore = Get-HCXDatastore -Name $DestinationStorage -Site $DestSite -ErrorAction Stop
            $DestContainer = Get-HCXContainer -Name $DestinationContainer -Site $DestSite -Type "Folder"

        } Catch {
            $ercode = 1
            write-mylog "Unable to obtain and set compute information"
            $finalcode = "Getting Compute Information Failed. This doesn't normally happen. $_.ErrorDetails"
        }
    } 

    ## Create and Test Migration
    If ($ercode -eq 0){
        write-mylog "Testing Migration"
        $Migration = New-HCXMigration -DestinationSite $DestSite -NetworkMapping $NetworkMappings -MigrationType "RAV" -SourceSite $SrcSite -TargetComputeContainer $DestCompute -Folder $DestContainer -DiskProvisionType $DestinationProvisioning -TargetDatastore $DestDataStore -Vm $hcxvm -RemoveISOs:$true -ScheduleStartTime $StartTime -ScheduleEndTime $EndTime
        Try {
            Test-HCXMigration -Migration $Migration -ErrorAction Stop
        } Catch {
            If ($_.FullyQualifiedErrorId -eq "VMware.VimAutomation.Hcx.Impl.V1.Service.HCXMigrationService,VMware.VimAutomation.Hcx.Commands.Cmdlets.TestHCXMigration"){
                write-mylog "CBT Enabled for $mignm. Proceeding....."
            } Else {
                write-mylog "Migration Validation Failed for $mignm"
                $ercode = 1
                $finalcode = "Testing Validation Failed. $_.ErrorDetails"
            }
        }
    }

    ## Run Migration
    If ($ercode -eq 0){
        write-mylog "Scheduling Migration"
        Try {
            $MigrationStatus = Start-HCXMigration -Migration $Migration -Confirm:$false -ErrorAction Stop
        } Catch {
            $ercode = 1
            write-mylog "Error scheduling migration for $mignm. $_.FullyQualifiedErrorId"
            $finalcode = "Error scheduling migration for $mignm. $_.FullyQualifiedErrorId"
        }
    }

    If ($ercode -eq 0){
        $MigVM = $MigrationStatus.VM
        $MigDS = $MigrationStatus.DestinationSite
        $MigSC = $MigrationStatus.SourceSite
        $MigNetMap = "$SrcNetName > $DestNetName"
        $MigType = $MigrationStatus.MigrationType
        $MigDC = $MigrationStatus.TargetComputeContainer
        $MigDDS = $MigrationStatus.TargetDatastore
        $MigDT = $MigrationStatus.DiskProvisionType

        write-mylog "----------- Success -------------"
        write-mylog "Migration Scheduled   : $MigVM"
        write-mylog "Source Site           : $MigSC"
        write-mylog "Migration Type        : $MigType"
        write-mylog "Network Map           : $MigNetMap"
        write-mylog "Destination Site      : $MigDS"
        write-mylog "Destination Cluster   : $MigDC"
        write-mylog "Destination Datastore : $MigDDS"
        write-mylog "Destination Disk Type : $MigDT"

    } Else {
        write-mylog "----------- Failed -------------"
        write-mylog "VM Name : $mignm "
        write-mylog "Reason  : $FinalCode"
    }
    
    write-mylog "-------------------------------------------------------------------------------"
    $lasthcxmgr = $hcxmanager
}   
$Trash = Disconnect-HCXServer * -Confirm:$false -Force
$Trash = Disconnect-VIServer * -Confirm:$false -Force
write-mylog "Complete"
Write-Output "See Log File @ $LogFile"