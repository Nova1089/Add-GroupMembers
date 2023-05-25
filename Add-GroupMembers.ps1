<#
This script adds a list of owners or members to a Microsoft 365 group.
#>

# functions
function Show-Introduction
{
    Write-Host "This script adds a list of owners or members to a Microsoft 365 group." -ForegroundColor DarkCyan
    Read-Host "Press Enter to continue"
}

function Use-Module($moduleName)
{    
    $keepGoing = -not(Test-ModuleInstalled $moduleName)
    while ($keepGoing)
    {
        Prompt-InstallModule($moduleName)
        Test-SessionPrivileges
        Install-Module $moduleName

        if ((Test-ModuleInstalled $moduleName) -eq $true)
        {
            Write-Host "Importing module..." -ForegroundColor DarkCyan
            Import-Module $moduleName
            $keepGoing = $false
        }
    }
}

function Test-ModuleInstalled($moduleName)
{    
    $module = Get-Module -Name $moduleName -ListAvailable
    return ($null -ne $module)
}

function Prompt-InstallModule($moduleName)
{
    do 
    {
        Write-Warning "$moduleName module is required."
        $confirmInstall = Read-Host -Prompt "Would you like to install the module? (y/n)"
    }
    while ($confirmInstall -inotmatch "(?<!\S)y(?!\S)") # regex matches a y but allows spaces
}

function Test-SessionPrivileges
{
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentSessionIsAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($currentSessionIsAdmin -ne $true)
    {
        Throw "Please run script with admin privileges. 
            1. Open Powershell as admin.
            2. CD into script directory.
            3. Run .\scriptname.ps1"
    }
}

function TryConnect-ExchangeOnline
{
    $connectionStatus = Get-ConnectionInformation -ErrorAction SilentlyContinue

    while ($null -eq $connectionStatus)
    {
        Write-Host "Connecting to Exchange Online..." -ForegroundColor DarkCyan
        Connect-ExchangeOnline -ErrorAction SilentlyContinue
        $connectionStatus = Get-ConnectionInformation

        if ($null -eq $connectionStatus)
        {
            Read-Host -Prompt "Failed to connect to Exchange Online. Press Enter to try again"
        }
    }
}

function Prompt-GroupIdentifier
{
    do
    {
        $groupIdentifier = Read-Host "Enter name or email of Microsoft 365 group"
        $group = TryGet-MSGroup -groupIdentifier $groupIdentifier -tellWhenFound
    }
    while ($null -eq $group)

    return $group.PrimarySMTPAddress
}

function TryGet-MSGroup($groupIdentifier, [switch]$tellWhenFound)
{
    $group = Get-UnifiedGroup -Identity $groupIdentifier -ErrorAction SilentlyContinue
    if ($null -eq $group)
    {
        Write-Warning "MS Group was not found: $groupIdentifier."
        return $null
    }

    if ($group.Count -gt 1)
    {
        Write-Warning "More than one group was found with the given identifier: $groupIdentifier."
        $group | Out-Host
        return $null
    }

    if ($tellWhenFound)
    {
        Write-Host "Found group." -ForegroundColor DarkCyan
        $group | Out-Host
    }
    return $group
}

function Prompt-UserListInputMethod
{
    Write-Host "Choose user input method:"
    do
    {
        $choice = Read-Host ("[1] Provide text file. (Users listed by full name or email, separated by new line.)`n" +
                             "[2] Enter user list manually.`n")        
    }
    while ($choice -notmatch '(?<!\S)[12](?!\S)') # regex matches a 1 or 2 but allows whitespace

    return [int]$choice
}

function Get-UsersFromTXT
{
    do 
    {
        $path = Read-Host "Enter path to txt file. (i.e. C:\UserList.txt)"
        $userList = Get-Content -Path $path -ErrorAction SilentlyContinue 
        
        if ($null -eq $userList)
        {
            Write-Warning "File not found or contents are empty."
            $keepGoing = $true
            continue
        }
        else
        {
            $keepGoing = $false
        }

        $finalUserList = New-Object -TypeName System.Collections.Generic.List[string]
        $i = 0
        foreach ($user in $userList)
        {
            if (($null -eq $user) -or ("" -eq $user)) { continue }
            
            if ($null -eq (TryGet-Mailbox $user))
            {                
                $keepGoing = Prompt-YesOrNo "Would you like to fix the file and try again?"
                if ($keepGoing) { break }
            }
            else
            {
                $finalUserList.Add($user)
            }
            $i++
            Write-Progress -Activity "Looking up users..." -Status "$i users checked."
        }
    }
    while ($keepGoing)

    return $finalUserList
}

function Prompt-YesOrNo($question)
{
    do
    {
        $response = Read-Host "$question y/n"
    }
    while ($response -inotmatch '(?<!\S)[yn](?!\S)') # regex matches y or n but allows spaces

    if ($response -imatch '(?<!\S)y(?!\S)') # regex matches a y but allows spaces
    {
        return $true
    }
    return $false   
}

function Get-UsersManually
{
    $userList = New-Object -TypeName System.Collections.Generic.List[string]

    while ($true)
    {
        $response = Read-Host "Enter a user (full name or email) or type `"done`""
        if ($response -imatch '(?<!\S)done(?!\S)') { break } # regex matches the word "done" but allows spaces
        if ($null -eq (TryGet-Mailbox $response -tellWhenFound)) { continue }
        $userList.Add($response)
    }

    return $userList
}

function TryGet-Mailbox($mailboxIdentifier, [switch]$tellWhenFound)
{
    $mailbox = Get-EXOMailbox -Identity $mailboxIdentifier -ErrorAction SilentlyContinue

    if ($null -eq $mailbox)
    {
        Write-Warning "User not found: $mailboxIdentifier."
        return $null
    }

    if ($tellWhenFound)
    {
        Write-Host "Found user:" -ForegroundColor DarkCyan
        $mailbox | Format-Table -Property DisplayName, @{Label="Email"; Expression = {$_.PrimarySMTPAddress}} | Out-Host
    }
    return $mailbox
}

function Prompt-MembershipType
{
    Write-Host "Choose membership type to grant:"
    do
    {
        $choice = Read-Host ("[1] Owner`n" +
                             "[2] Member`n")
    }
    while ($choice -notmatch '(?<!\S)[12](?!\S)') # regex matches a 1 or 2 but allows whitespaces

    if ($choice -eq 1)
    {
        Write-Host "Please note: To be added as owners, users will also be added as members." -ForegroundColor DarkCyan
        Read-Host "Press Enter to continue"
    }

    return [int]$choice
}

function Add-GroupMembers($groupIdentifier, $userList, $makeOwners)
{
    $i = 0
    foreach ($user in $userList)
    {
        Write-Progress -Activity "Adding members to group..." -Status "$i members added."

        Add-UnifiedGroupLinks -Identity $groupIdentifier -Links $user -LinkType Members # add user as a member

        if ($makeOwners)
        {
            Add-UnifiedGroupLinks -Identity $groupIdentifier -Links $user -LinkType Owners # add user as an owner
        }
        $i++
    }
    Write-Progress -Activity "Adding members to group..." -Status "$i members added."
    Write-Host "Finished adding $i users to the group. (If they weren't members already.)" -ForegroundColor DarkCyan
}

# main
Show-Introduction
Use-Module("ExchangeOnlineManagement")
TryConnect-ExchangeOnline

$groupIdentifier = Prompt-GroupIdentifier
$userListInputMethod = Prompt-UserListInputMethod
switch ($userListInputMethod)
{
    1 { $userList = Get-UsersFromTXT }
    2 { $userList = Get-UsersManually }
}

$memberType = Prompt-MembershipType
switch  ($memberType)
{
    1 { $makeOwners = $true }
    2 { $makeOwners = $false }
}
Add-GroupMembers -groupIdentifier $groupIdentifier -userList $userList -makeOwners $makeOwners

Read-Host -Prompt "Press Enter to exit"