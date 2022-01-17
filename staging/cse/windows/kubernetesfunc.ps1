function Get-ProvisioningScripts {
    Write-Log "Getting provisioning scripts"
    DownloadFileOverHttp -Url $global:ProvisioningScriptsPackageUrl -DestinationPath 'c:\k\provisioningscripts.zip'
    Expand-Archive -Path 'c:\k\provisioningscripts.zip' -DestinationPath 'c:\k' -Force
    Remove-Item -Path 'c:\k\provisioningscripts.zip' -Force
}

function Get-WindowsVersion {
    $systemInfo = Get-ItemProperty -Path "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    return "$($systemInfo.CurrentBuildNumber).$($systemInfo.UBR)"
}

function Get-InstanceMetadataServiceTelemetry {
    $keys = @{ }

    try {
        # Write-Log "Querying instance metadata service..."
        # Note: 2019-04-30 is latest api available in all clouds
        $metadata = Invoke-RestMethod -Headers @{"Metadata" = "true" } -URI "http://169.254.169.254/metadata/instance?api-version=2019-04-30" -Method get
        # Write-Log ($metadata | ConvertTo-Json)

        $keys.Add("vm_size", $metadata.compute.vmSize)
    }
    catch {
        Write-Log "Error querying instance metadata service."
    }

    return $keys
}

function Initialize-DataDirectories {
    # Some of the Kubernetes tests that were designed for Linux try to mount /tmp into a pod
    # On Windows, Go translates to c:\tmp. If that path doesn't exist, then some node tests fail

    $requiredPaths = 'c:\tmp'

    $requiredPaths | ForEach-Object {
        Create-Directory -FullPath $_
    }
}

function Get-LogCollectionScripts {
    # github.com is not in the required endpoints https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic
    # We only can copy below scripts from cache folder in the VHD
    # To add a new script, you need
    #  1. Add the script in vhdbuilder/packer/generate-windows-vhd-configuration.ps1
    #  2. Build a new AKS Windows VHD and update the VHD version in AKS RP
    #  3. Update this function to add the script
    Write-Log "Copying various log collect scripts and depencencies"
    $destinationFolder='c:\k\debug'
    Create-Directory -FullPath $destinationFolder -DirectoryUsage "storing debug scripts"
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'collect-windows-logs.ps1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'collectlogs.ps1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'dumpVfpPolicies.ps1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'portReservationTest.ps1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'starthnstrace.cmd'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'startpacketcapture.cmd'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'stoppacketcapture.cmd'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'VFP.psm1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'helper.psm1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'hns.psm1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'starthnstrace.ps1'
    CopyFileFromCache -DestinationFolder $destinationFolder -FileName 'startpacketcapture.ps1'
}

function Register-LogsCleanupScriptTask {
    Write-Log "Creating a scheduled task to run windowslogscleanup.ps1"

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"c:\k\windowslogscleanup.ps1`""
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $trigger = New-JobTrigger -Daily -At "00:00" -DaysInterval 1
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "log-cleanup-task"
    Register-ScheduledTask -TaskName "log-cleanup-task" -InputObject $definition
}

function Register-NodeResetScriptTask {
    Write-Log "Creating a startup task to run windowsnodereset.ps1"

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"c:\k\windowsnodereset.ps1`""
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $trigger = New-JobTrigger -AtStartup -RandomDelay 00:00:05
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "k8s-restart-job"
    Register-ScheduledTask -TaskName "k8s-restart-job" -InputObject $definition
}

# TODO ksubrmnn parameterize this fully
function Write-KubeClusterConfig {
    param(
        [Parameter(Mandatory = $true)][string]
        $MasterIP,
        [Parameter(Mandatory = $true)][string]
        $KubeDnsServiceIp
    )

    $Global:ClusterConfiguration = [PSCustomObject]@{ }

    $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cri -Value @{
        Name   = $global:ContainerRuntime;
        Images = @{
            # e.g. "mcr.microsoft.com/oss/kubernetes/pause:1.4.1"
            "Pause" = $global:WindowsPauseImageURL
        }
    }

    $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Cni -Value @{
        Name   = $global:NetworkPlugin;
        Plugin = @{
            Name = "bridge";
        };
    }

    $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Csi -Value @{
        EnableProxy = $global:EnableCsiProxy
    }

    $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Kubernetes -Value @{
        Source       = @{
            Release = $global:KubeBinariesVersion;
        };
        ControlPlane = @{
            IpAddress    = $MasterIP;
            Username     = "azureuser"
            MasterSubnet = $global:MasterSubnet
        };
        Network      = @{
            ServiceCidr = $global:KubeServiceCIDR;
            ClusterCidr = $global:KubeClusterCIDR;
            DnsIp       = $KubeDnsServiceIp
        };
        Kubelet      = @{
            NodeLabels = $global:KubeletNodeLabels;
            ConfigArgs = $global:KubeletConfigArgs
        };
        Kubeproxy    = @{
            FeatureGates = $global:KubeproxyFeatureGates;
            ConfigArgs   = $global:KubeproxyConfigArgs
        };
    }

    $Global:ClusterConfiguration | Add-Member -MemberType NoteProperty -Name Install -Value @{
        Destination = "c:\k";
    }

    $Global:ClusterConfiguration | ConvertTo-Json -Depth 10 | Out-File -FilePath $global:KubeClusterConfigPath
}

function Update-DefenderPreferences {
    Add-MpPreference -ExclusionProcess "c:\k\kubelet.exe"

    if ($global:EnableCsiProxy) {
        Add-MpPreference -ExclusionProcess "c:\k\csi-proxy-server.exe"
    }

    if ($global:ContainerRuntime -eq 'containerd') {
        Add-MpPreference -ExclusionProcess "c:\program files\containerd\containerd.exe"
    }
}

function Check-APIServerConnectivity {
    Param(
        [Parameter(Mandatory = $true)][string]
        $MasterIP,
        [Parameter(Mandatory = $false)][int]
        $RetryInterval = 1,
        [Parameter(Mandatory = $false)][int]
        $ConnectTimeout = 10,  #seconds
        [Parameter(Mandatory = $false)][int]
        $MaxRetryCount = 100
    )
    $retryCount=0

    do {
        try {
            $tcpClient=New-Object Net.Sockets.TcpClient
            Write-Log "Retry $retryCount : Trying to connect to API server $MasterIP"
            $tcpClient.ConnectAsync($MasterIP, 443).wait($ConnectTimeout*1000)
            if ($tcpClient.Connected) {
                $tcpClient.Close()
                Write-Log "Retry $retryCount : Connected to API server successfully"
                return
            }
            $tcpClient.Close()
        } catch {
            Write-Log "Retry $retryCount : Failed to connect to API server $MasterIP. Error: $_"
        }
        $retryCount++
        Write-Log "Retry $retryCount : Sleep $RetryInterval and then retry to connect to API server"
        Sleep $RetryInterval
    } while ($retryCount -lt $MaxRetryCount)

    Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_CHECK_API_SERVER_CONNECTIVITY -ErrorMessage "Failed to connect to API server $MasterIP after $retryCount retries"
}

function Get-CACertificates {
    try {
        Write-Log "Get CA certificates"
        $caFolder = "C:\ca"
        $uri = 'http://168.63.129.16/machine?comp=acmspackage&type=cacertificates&ext=json'

        Create-Directory -FullPath $caFolder -DirectoryUsage "storing CA certificates"

        Write-Log "Download CA certificates rawdata"
        # This is required when the root CA certs are different for some clouds.
        try {
            $rawData = Retry-Command -Command 'Invoke-WebRequest' -Args @{Uri=$uri; UseBasicParsing=$true} -Retries 5 -RetryDelaySeconds 10
        } catch {
            Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_DOWNLOAD_CA_CERTIFICATES -ErrorMessage "Failed to download CA certificates rawdata. Error: $_"
        }

        Write-Log "Convert CA certificates rawdata"
        $caCerts=($rawData.Content) | ConvertFrom-Json
        if ([string]::IsNullOrEmpty($caCerts)) {
            Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_EMPTY_CA_CERTIFICATES -ErrorMessage "CA certificates rawdata is empty"
        }

        $certificates = $caCerts.Certificates
        for ($index = 0; $index -lt $certificates.Length ; $index++) {
            $name=$certificates[$index].Name
            $certFilePath = Join-Path $caFolder $name
            Write-Log "Write certificate $name to $certFilePath"
            $certificates[$index].CertBody > $certFilePath
        }
    }
    catch {
        # Catch all exceptions in this function. NOTE: exit cannot be caught.
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_GET_CA_CERTIFICATES -ErrorMessage $_
    }
}