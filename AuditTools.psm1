<#
 Tool:    AuditTools.psm1
 Author:  Derek Ardolf
 NOTES:   This module has been smashed together by
    scripts I have converted into functions. Error checking
    is mostly absent, and comment-based help is too.
#>

function Get-ATLocalGroupMembers {
[CmdletBinding()]
param (
  [Parameter (Mandatory=$False)]
  [string[]]$ComputerName = @($env:COMPUTERNAME)
  [ValidateSet('WSMan','Dcom')]
  [string]$Protocol = 'WSMan',
  [switch]$CheckActiveDirectory,
  [PSCredential]$Credential
)
  if ($CheckActiveDirectory) {
    Import-Module ActiveDirectory -ErrorAction Stop
  }
  $Option = New-CimSessionOption -Protocol $Protocol
  foreach ($Computer in $ComputerName) {
    try {
      if ($Credential) {
        $Session = New-CimSession -Credential $Credential -ComputerName $Computer -SessionOption $Option
      }
      else {
        $Session = New-CimSession -ComputerName $Computer -SessionOption $Option
      }
    }
    catch {
      break
    }
    $LocalGroups = Get-CimInstance -CimSession $Session -ClassName win32_group -Filter 'LocalAccount=TRUE'
    $GroupUsers = @()
    foreach ($Local in $LocalGroups) {
      $Query = "SELECT * FROM Win32_GroupUser WHERE GroupComponent=`"Win32_Group.Domain='$($Local.Domain)',Name='$($Local.Name)'`""
      $GroupUsers += Get-CimInstance -CimSession $Session -Query "$Query"
    }
    foreach ($Member in $GroupUsers) {
      [PSCustomObject]@{'PSComputerName'=$Member.PSComputerName
          'Name'=$Member.PartComponent.Name
          'Domain'=$Member.PartComponent.Domain
          'DomainAndName'="$($Member.PartComponent.Domain)\$($Member.PartComponent.Name)"
          'LocalMemberOf'="$($Member.GroupComponent.Domain)\$($Member.GroupComponent.Name)"
          'ADMemberOf'="$($Member.GroupComponent.Domain)\$($Member.GroupComponent.Name)"} 
      if ($Member.PartComponent.Domain -notlike "$($Member.PSComputerName)*" -and $CheckActiveDirectory -and $Member.PartComponent.Name -ne 'Domain Users') {
        $ADSingleUser = Get-ADUser -Identity $Member.PartComponent.Name -Server $Member.PartComponent.Domain -ErrorAction SilentlyContinue
        if ($ADSingleUser) {
          [PSCustomObject]@{'PSComputerName'=$Member.PSComputerName
                  'Name'=$ADSingleUser.Name
                  'Domain'=$Member.PartComponent.Domain
                  'DomainAndName'="$($Member.PartComponent.Domain)\$($ADSingleUser.Name)"
                  'LocalMemberOf'="$($Member.GroupComponent.Domain)\$($Member.GroupComponent.Name)"
                  'ADMemberOf'="$($Member.PartComponent.Domain)\$($Member.PartComponent.Name)"}
          $ADSingleUser = $null
        }
        else {
          $ADUsers = Get-ADGroup $Member.PartComponent.Name -Server $Member.PartComponent.Domain | 
            Get-ADGroupMember -Server $Member.PartComponent.Domain -Recursive
          foreach ($ADUser in $ADUsers) {
            [PSCustomObject]@{'PSComputerName'=$Member.PSComputerName
                              'Name'=$ADUser.Name
                              'Domain'=$Member.PartComponent.Domain
                              'DomainAndName'="$($Member.PartComponent.Domain)\$($ADUser.Name)"
                              'LocalMemberOf'="$($Member.GroupComponent.Domain)\$($Member.GroupComponent.Name)"
                              'ADMemberOf'="$($Member.PartComponent.Domain)\$($Member.PartComponent.Name)"}        
          }
        }
      }
    }
    Remove-CimSession $Session
  }
}

function Get-ATADUnixAttribute {
[CmdletBinding()]
param (
  [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,ValueFromPipeline=$true)]
  [String[]]$Name
)
  Process {
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($User in $Name) {
      Get-ADUser $User -Properties * | 
        select SamAccountName,msSFU30NisDomain,unixHomeDirectory,loginShell,uidNumber,gidnumber,
          @{Label='PrimaryGroupDN';Expression={(Get-ADGroup -Filter {GIDNUMBER -eq $_.gidnumber}).DistinguishedName}}
    }
  }
}

function Get-ATADFSMO {
  Import-Module ActiveDirectory -ErrorAction Stop
  $domaininfo = Get-ADDomain | select PDCEmulator,RIDMaster,InfrastructureMaster
  $forestinfo = Get-ADForest | select SchemaMaster,DomainNamingMaster
  
  # FSMO Roles
  $props = @{'SchemaMaster'=$forestinfo.SchemaMaster
             'DomainNamingMaster'=$forestinfo.DomainNamingMaster         
             'PDCEmulator'=$domaininfo.PDCEmulator      
             'RIDMaster'=$domaininfo.RIDMaster         
             'InfrastructureMaster'=$domaininfo.InfrastructureMaster}
  New-Object -TypeName PSObject -Property $props
} #End of Function Get-ATADFSMO

function Get-ATADSite {
[CmdletBinding()]
param (
  [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true)]
  [Alias("SiteName","Sites")]
  [String[]]$Name
)
  Begin {
    $configNCDN = (Get-ADRootDSE).ConfigurationNamingContext
    $siteContainerDN = ("CN=Sites," + $configNCDN)
  }
  Process {
    if (!$Name) {
      $Name = (Get-ADObject -Filter {ObjectClass -eq "Site"} -SearchBase $siteContainerDN).Name
    }
    foreach ($Item in $Name) {
      $siteDN = "CN=" + $Item + "," + $siteContainerDN
      Get-ADObject -Identity $siteDN -properties Name,DisplayName,DistinguishedName,Description,ObjectClass,whenChanged,whenCreated
    }
  }
} #End of Function Get-ATADSite

function Get-ATADSiteSubnet {
[CmdletBinding()]
param (
  [Parameter(Mandatory=$true,ValueFromPipeLine=$True)]
  [Alias("SiteName")]
  [String[]]$Name
) 
  Begin {
    Import-Module ActiveDirectory -ErrorAction Stop
    $configNCDN = (Get-ADRootDSE).ConfigurationNamingContext
    $siteContainerDN = ("CN=Sites," + $configNCDN)
  }
  Process {
    foreach ($Site in $Name) {
      $siteDN = "CN=" + $Site + "," + $siteContainerDN
      $siteObj = Get-ADObject -Identity $siteDN -Properties "siteObjectBL", "description", "location" -ErrorAction SilentlyContinue
      foreach ($subnetDN in $siteObj.siteObjectBL) {
          Get-ADObject -Identity $subnetDN -Properties siteObject,description,location,whenChanged,whenCreated |
            Select Name,Description,ObjectClass,@{Label='SiteName';Expression={($_.siteobject -replace ",CN=Sites.*","").Substring(3)}},
                    whenChanged,whenCreated
      }
    }
  }
} #End of Function Get-ATADSiteSubnet

function Get-ATADSiteLink {
  Import-Module ActiveDirectory -ErrorAction Stop
  # Finding SiteLinks
  $sites = Get-ADObject -LDAPFilter '(objectclass=sitelink)' `
    -SearchBase (Get-ADRootDSE).ConfigurationNamingContext `
    -Properties Name,ReplInterval,Description,Sitelist,ObjectClass,whenCreated,whenChanged
  # Finding member Sites of each SiteLink
  foreach ($site in $sites) {
    $sitelist = $site | Select-Object -ExpandProperty SiteList
    $allsites = @()
    foreach ($sitelistitem in $sitelist) {
      $allsites += ($sitelistitem -replace ",CN=Sites.*","").Substring(3)
    }
    # Data being output
    $props = [ordered]@{'Name'=$site.Name
                        'ObjectClass'="siteLink"
                        'ReplInterval'=$site.ReplInterval
                        'Sites'=$allsites
                        'Description'=$site.Description
                        'whenChanged'=$site.whenChanged
                        'whenCreated'=$site.whenCreated}
    New-Object -TypeName PSObject -Property $props
    Clear-Variable allsites
  }
} #End of Function Get-ATADSiteLink

function Get-ATADTrust {
  Import-Module ActiveDirectory -ErrorAction Stop
  $trusteddomains = Get-ADObject -Filter {ObjectClass -eq "TrustedDomain"} -SearchBase "CN=System,$((Get-ADDomain).DistinguishedName)" -Properties trustDirection,trustType
  foreach ($trust in $trusteddomains) {
    switch ($trust.TrustDirection) {
      0       {$direction = "Disabled"}
      1       {$direction = "Outbound"}
      2       {$direction = "inBound"}
      3       {$direction = "Bi-Directional"}
      default {$direction = "Undefined"}
    }
  
    switch ($trust.TrustType) {
      1       {$type = "DownLevel"}
      2       {$type = "UpLevel"}
      3       {$type = "MIT"}
      4       {$type = "DCE"}
      default {$type = "Undefined"}
    }

    $props = @{'Domain'=$trust.Name;
      'TrustType'=$type;
      'TrustDirection'=$direction}
    New-Object -TypeName PSObject -Property $props
    Clear-Variable direction,type
  }
} #End of Function Get-ATADTrust

function Get-ATLocalAdminMember {
<#
	.SYNOPSIS
		Query servers for local Administrators.

	.DESCRIPTION
		Get-ATLocalAdminMember queries targets with PowerShell Remoting, and then uses the Microsoft Active Directory Module to pull AD-related information about all users that have Administrative access. This script will work against servers, as long as those servers have PowerShell Remoting enabled, and are in a domain. The machine running this script must have the Microsoft Active Directory Module installed.

	.PARAMETER ComputerName
		The target computer, or list of computers (seperated by commas), that the script will query over PowerShell remoting.
    
  .PARAMETER CheckActiveDirectory
    Run the results against Active Directory to retrieve basic AD user, and group information. This switch will also run recursively against AD, in order to reveal complete visibility of Administrators for a server.

	.PARAMETER Credential
		If running the script under alternative credentials.

	.EXAMPLE
		PS C:\> Get-ATLocalAdminMember -ComputerName SERVER101 -Credential $Creds
      Runs the script against SERVER101, returns all members of local Administrators, and queries against Active Directory for user/group information. This uses alternate credentials that have been stored in the $Creds variable, using Get-Credential.

	.EXAMPLE
		PS C:\> Get-ATLocalAdminMember -ComputerName SERVER101,SERVER102 -Credential $Creds | Export-Csv C:\temp\audit.csv -NoTypeInformation
      Runs the script against SERVER101 and SERVER102, returns all members of local Administrators, and queries against Active Directory for user/group information. This uses alternate credentials that have been stored in the $Creds variable, using Get-Credential. The results are saved in a CSV spreadsheet, C:\temp\audit.csv.

  .EXAMPLE
    PS C:\> Get-ATLocalAdminMember -ComputerName (cat c:\temp\complist.txt) | Export-Csv C:\temp\audit.csv -NoTypeInformation -Append
      Runs the script against a list of servers in complist.txt, returns all members of local Administrators, and queries against Active Directory for user/group information. This uses the credentials of the currently logged in user. The results are appended/added to a CSV spreadsheet, or it creates a new one if not currently existing, called C:\temp\audit.csv.

	.INPUTS
		System.String
    System.Management.Automation.PSCredential

	.OUTPUTS
		System.Management.Automation.PSCustomObject

	.NOTES

  .LINK
    https://github.com/ScriptAutomate/AuditTools

	.LINK
		about_Remote_Requirements

	.LINK
		about_Remote_Troubleshooting

#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$False)]
  [String[]]$ComputerName = $env:COMPUTERNAME,
  [Parameter(Mandatory=$false)]
  [Switch]$CheckActiveDirectory,
  [Parameter(Mandatory=$False)]
  [System.Management.Automation.PSCredential]$Credential
)
  if ($CheckActiveDirectory) {Import-Module ActiveDirectory -ErrorAction Stop}

  # If using alternate credentials
  if ($Credential) {
    $Sessions = New-PSSession -ComputerName $ComputerName -Credential $Credential
  }
  else {$Sessions = New-PSSession -ComputerName $ComputerName}

  if ($Sessions) {
    $LocalAdmins = Invoke-Command -Session $Sessions -ScriptBlock {
      $objSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
      $objgroup = $objSID.Translate( [System.Security.Principal.NTAccount])
      $objgroupname = ($objgroup.Value).Split("\")[1]
      $group =[ADSI]"WinNT://$($ENV:ComputerName)/$objgroupname" 
      $members = $group.psbase.Invoke("Members")
      foreach ($member in $members) {
        $MemberPath = ($member.GetType().Invokemember("ADSPath", 'GetProperty', $null, $member, $null)) -replace "WinNT://$($ENV:USERDOMAIN)/",''
        if ($MemberPath -Match "/") {
          $IsDomainAccount = $false
          $DomainName = $ENV:COMPUTERNAME
          $MemberPath = $MemberPath -replace ".*/",''
        }
        else {
          $IsDomainAccount = $true
          $DomainName = $ENV:USERDOMAIN
        }
        New-Object PSObject -Property @{
          MemberName = $member.GetType().Invokemember("Name", 'GetProperty', $null, $member, $null)
          MemberType = $member.GetType().Invokemember("Class", 'GetProperty', $null, $member, $null)
          MemberPath = $MemberPath 
          IsDomainAccount = $IsDomainAccount
          DomainName = $DomainName
        }
      } 
    }
    Remove-PSSession $Sessions

    # If the query above returned anything, run results against Active Directory
    if ($CheckActiveDirectory) {
      if ($LocalAdmins) {
        $DomainName = (Get-ADDomain).NETBIOSNAME
        # Modifying output, and querying AD
        foreach ($LocalAdmin in $LocalAdmins) {
          if ($LocalAdmin.IsDomainAccount -eq $false) {
            $IsDomainAccount = $False
            $MemberOf = "$($LocalAdmin.PSComputerName)\Administrators"
            $DN = "N/A"
            $SAMAccountName = "N/A"
            $Props = @{"Name"=$LocalAdmin.MemberName
                       "MemberType"=$LocalAdmin.MemberType
                       "PSComputerName"=$LocalAdmin.PSComputerName
                       "IsDomainAccount"=$IsDomainAccount
                       "SamAccountName"=$SamAccountName
                       "AdminByMemberOf"=$MemberOf
                       "DN"=$DN}
            New-Object -TypeName PSObject -Property $Props
          }
          else {
            $IsDomainAccount = $True
            $MemberOf = "$($LocalAdmin.PSComputerName)\Administrators"
            if ($LocalAdmin.MemberType -eq "User") {
              $ADObject = Get-ADUser -Identity "$($LocalAdmin.MemberName)"
            }
            else {$ADObject = Get-ADGroup -Identity "$($LocalAdmin.MemberName)"}
            $Props = @{"Name"=$ADObject.Name
                       "MemberType"=$LocalAdmin.MemberType
                       "PSComputerName"=$LocalAdmin.PSComputerName
                       "IsDomainAccount"=$IsDomainAccount
                       "SamAccountName"=$ADObject.SamAccountName
                       "AdminByMemberOf"=$MemberOf
                       "DN"=$ADObject.DistinguishedName}
            New-Object -TypeName PSObject -Property $Props
            if ($LocalAdmin.MemberType -eq "Group") {
              $GroupMembers = Get-ADGroupMember -Identity "$($LocalAdmin.MemberName)" -Recursive
              foreach ($GroupMember in $GroupMembers) {
                $Props = @{"Name"=$GroupMember.Name
                           "MemberType"=$GroupMember.ObjectClass
                           "PSComputerName"=$LocalAdmin.PSComputerName
                           "IsDomainAccount"=$IsDomainAccount
                           "SamAccountName"=$GroupMember.SamAccountName
                           "AdminByMemberOf"=$LocalAdmin.MemberName
                           "DN"=$GroupMember.DistinguishedName}
                New-Object -TypeName PSObject -Property $Props
                Clear-Variable Props
              }
            }
            Clear-Variable Props
          }
        }
      }
    }
    else {$LocalAdmins | select * -ExcludeProperty RunspaceId,PSShowComputerName}
  }
} #End of Function Get-ATLocalAdminMember

function Get-ATShareHunter {
[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [String[]]$ComputerName = $env:COMPUTERNAME,
  [Parameter(Mandatory=$false)]
  [Switch]$AllEnabledComputers,
  [Parameter(Mandatory=$False)]
  [System.Management.Automation.PSCredential]$Credential
)
  if ($AllEnabledComputers) {
    $ComputerList = (Get-ADComputer -Filter * -Properties Enabled | where {$_.Enabled -eq $True}).Name
  }
  else {
    $ComputerList = $ComputerName
  }
  $splat = @{ComputerName=$ComputerList}
  if ($Credential) {
    $splat += @{Credential=$Credential}
  }
  else {
    Invoke-Command @splat -ScriptBlock {Get-WmiObject win32_share}
  }
} #End of Function Get-ATShareHunter

function Get-ATShareACL {
# http://blogs.technet.com/b/ashleymcglone/archive/2014/03/17/powershell-to-find-where-your-active-directory-groups-are-used-on-file-shares.aspx
[CmdletBinding()]
param (
  [Parameter(Mandatory=$True,ValueFromPipelineByPropertyName=$True)]
  [Alias('ComputerName')]
  [String[]]$PSComputerName,
  [Parameter(Mandatory=$True,ValueFromPipelineByPropertyName=$True)]
  [String[]]$Path,
  [Parameter(Mandatory=$False)]
  [System.Management.Automation.PSCredential]$Credential
)
  Process {
    $splat = @{ComputerName=$PSComputerName}
    if ($Credential) {
      $splat += @{Credential=$Credential}
    }
    Invoke-Command @splat -ScriptBlock {
      Write-Verbose "Collecting folders.."
      foreach ($Target in $Using:Path) {
        if ($Target) {
          $folders = @()            
          $folders += Get-Item $Target | Select-Object -ExpandProperty FullName       
          $subfolders = Get-Childitem $Target -ErrorAction SilentlyContinue |             
            Where-Object {$_.PSIsContainer -eq $true} |             
            Select-Object -ExpandProperty FullName            
          Write-Verbose "Completed collecting folders!"
                  
          # We don't want to add a null object to the list if there are no subfolders            
          If ($subfolders) {$folders += $subfolders}            
          $i = 0            
          $FolderCount = $folders.count            
                  
          ForEach ($folder in $folders) {               
            Write-Verbose "Scanning folders..."
            # Get-ACL cannot report some errors out to the ErrorVariable.            
            # Therefore we have to capture this error using other means.            
            Try {            
                $acl = Get-ACL -LiteralPath $folder -ErrorAction Continue            
            }            
            Catch {            
                Write-Warning "Unable to verify permissions on $folder..."          
            }              
            $acl.access |             
                Where-Object {$_.IsInherited -eq $false} |            
                Select-Object @{name='Root';expression={$Target}},
                              @{name='Path';expression={$folder}},
                              IdentityReference, FileSystemRights, IsInherited,
                              InheritanceFlags, PropagationFlags                   
          } 
        }
      }
    }
  }
} #End of Function Get-ATShareACL

function Get-ATADUserAudit {
[CmdletBinding()]
Param(
  [parameter(Mandatory=$false,Position=1)]
  [String]$Identity = $ENV:USERNAME
)
$TargetProperties = @("SamAccountName","DisplayName","Distinguishedname","Mail","Enabled","CannotChangePassword","PasswordNotRequired",
                      "PasswordNeverExpires","PasswordExpired","LockedOut","AccountLockoutTime","BadPwdCount","LastBadPasswordAttempt",
                      "LastLogonDate","LastLogoff","PasswordLastSet","whenChanged","whenCreated","memberof")
Get-ADUser -Identity $Identity -Properties $TargetProperties | 
  select $TargetProperties -ErrorAction SilentlyContinue
} #End of Function Get-ATADUserAudit

function Get-ATUptime {
# http://powershell.com/cs/blogs/tips/archive/2014/12/12/gettingsystemuptime.aspx
param (
  [String[]]$ComputerName,
  [Management.Automation.PSCredential]$Credential
)
  if ($ComputerName) {
    $splat = @{ ScriptBlock = {$millisec = [Environment]::TickCount
                              [Timespan]::FromMilliseconds($millisec)}
                ComputerName = $ComputerName}
    if ($Credential) {
      $splat += @{Credential = $Credential}
    }
    Invoke-Command @splat
  }
  else {
    $millisec = [Environment]::TickCount
    [Timespan]::FromMilliseconds($millisec)
  }
} #End of Function Get-ATUptime

function Get-ATADAccountPolicy {
<#
  .SYNOPSIS
    Obtain a domain's Account Lockout and Password policies.

  .DESCRIPTION
    Reads account lockout and password attributes from the domain header for a supplied domain.
    
  .PARAMETER DomainName
    Specifies the domain to search. The cmdlet locates a discoverable domain controller in this domain. Specify the domain by using the NetBIOS name or Fully Qualified Domain Name (FQDN) of the domain.

    The following example shows how to set this parameter to the FQDN of a domain:
      -DomainName "contoso.com"

  .EXAMPLE
    PS C:\> Get-ATDomainAccountPolicies -Domain contoso.com

    Returns the Account Lockout and Password policies for the contoso.com domain, e.g...

    DistinguishedName             : DC=contoso,DC=com
    lockoutDuration(Min)          : 30
    lockoutObservationWindow(Min) : 30
    lockoutThreshold              : 5
    minPwdAge(Days)               : 1
    maxPwdAge(Days)               : 60
    minPwdLength                  : 8
    pwdHistoryLength              : 24
    pwdProperties                 : Passwords must be complex, and the administrator account cannot be locked out

  .NOTES
    This function is a slightly modified version of the script provided by Ian Farr on the TechNet Script Gallery. You can find his script as the second related link.

  .LINK
    https://github.com/ScriptAutomate/AuditTools
  .LINK
    https://gallery.technet.microsoft.com/scriptcenter/Get-ADDomainAccountPolicies-d3a97a4f
#>
[CmdletBinding()]
Param(
  [parameter(Mandatory=$false,Position=1)]
  [ValidateScript({Get-ADDomain -Identity $_})] 
  [String]$DomainName = $ENV:USERDNSDOMAIN
)
  Import-Module ActiveDirectory -ErrorAction Stop
  $RootDSE = Get-ADRootDSE -Server $DomainName
  
  # List of policy properties being targeted
  $TargetProps = @("lockoutDuration","lockoutObservationWindow","lockoutThreshold","minPwdAge",
                   "maxPwdAge","minPwdLength","pwdHistoryLength","pwdProperties")
    
  $PolicyInfo = Get-ADObject $RootDSE.defaultNamingContext -Property $TargetProps

  #Output AD Policy Object
  $PolicyInfo | 
    Select  DistinguishedName,
            @{n="lockoutDuration(Min)";e={$_.lockoutDuration / -600000000}},
            @{n="lockoutObservationWindow(Min)";e={$_.lockoutObservationWindow / -600000000}},
            lockoutThreshold,
            @{n="minPwdAge(Days)";e={$_.minPwdAge / -864000000000}},
            @{n="maxPwdAge(Days)";e={$_.maxPwdAge / -864000000000}},
            minPwdLength,
            pwdHistoryLength,
            @{n="pwdProperties";e={Switch ($_.pwdProperties) { # Translate numeric value to readable definition
                                    0 {"Passwords can be simple, and the administrator account cannot be locked out"} 
                                    1 {"Passwords must be complex, and the administrator account cannot be locked out"} 
                                    8 {"Passwords can be simple, and the administrator account can be locked out"} 
                                    9 {"Passwords must be complex, and the administrator account can be locked out"} 
                                    Default {$_.pwdProperties}}
                                  }}
                                  
}  #End of Function Get-ATADAccountPolicy
