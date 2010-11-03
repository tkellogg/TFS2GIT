# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Author: Wilbert van Dolleweerd
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$GitRepository = "ConvertedFromTFS",
	[string]$WorkspaceName = "TFS2GIT",
	[bool]$CaseSensitive = $True
)

function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

function PrepareWorkspace
{
	$TempDir = GetTemporaryDirectory

	# Remove the temporary directory if it already exists.
	if (Test-Path $TempDir)
	{
		remove-item -path $TempDir -force -recurse		
	}
	
	md $TempDir | Out-null

	# Create the workspace and map it to the temporary directory we just created.
	tf workspace /delete $WorkspaceName /noprompt
	tf workspace /new /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName
	tf workfold /unmap /workspace:$WorkspaceName $/
	tf workfold /map /workspace:$WorkspaceName $TFSRepository $TempDir

	# We need this so the .git directory is hidden and will not be removed.
	git config --global core.hidedotfiles true
}


# Retrieve the history from Team Foundation Server, parse it line by line, 
# and use a regular expression to retrieve the individual changeset numbers.
function GetChangesetsFromHistory 
{
	$HistoryFileName = "history.txt"

	tf history $TFSRepository /recursive /noprompt /format:brief | Out-File $HistoryFileName

	# Necessary, because Powershell has some 'issues' with current directory. 
	# See http://huddledmasses.org/powershell-power-user-tips-current-directory/
	$FileWithCurrentPath =  (Convert-Path (Get-Location -PSProvider FileSystem)) + "\" + $HistoryFileName 
	
	$file = [System.IO.File]::OpenText($FileWithCurrentPath)
	# Skip first two lines 
	$line = $file.ReadLine()
	$line = $file.ReadLine()

	while (!$file.EndOfStream)
	{
		$line = $file.ReadLine()
		# Match digits at the start of the line
		$num = [regex]::Match($line, "^\d+").Value
		$ChangeSets = $ChangeSets + @([System.Convert]::ToInt32($num))
	}
	$file.Close()

	# Sort them from low to high.
	$ChangeSets = $ChangeSets | Sort-Object			 

	return $ChangeSets			 
}

# Actual converting takes place here.
function Convert ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	# Initialize a new git repository.
	Write-Host "Creating empty Git repository at", $TemporaryDirectory
	git init $TemporaryDirectory

	[bool]$RetrieveAll = $true
	foreach ($ChangeSet in $ChangeSets)
	{
		# Retrieve sources from TFS
		Write-Host "Retrieving sources from", $TFSRepository, "in", $TemporaryDirectory
		Write-Host "This is changeset", $ChangeSet

		if ($RetrieveAll)
		{
			# For the first changeset, we have to get everything.
			tf get $TemporaryDirectory /force /recursive /noprompt /version:C$ChangeSet | Out-Null
			$RetrieveAll = $false
		}
		else
		{
			# Now, only get the changed files.
			tf get $TemporaryDirectory /recursive /noprompt /version:C$ChangeSet | Out-Null
		}


		# Add sources to Git
		Write-Host "Adding sources to Git repository"
		pushd $TemporaryDirectory
		git add . | Out-Null
		$CommitMessageFileName = "commitmessage.txt"
		GetCommitMessage $ChangeSet $CommitMessageFileName

		# We don't want the commit message to be included, so we remove it from the index.
		# Not from the working directory, because we need it in the commit command.
		git rm $CommitMessageFileName --cached --force
		if (!($CaseSensitive)) {
			FixCaseSensitivity $CommitMessageFileName
		}
		
		git commit -a --file $CommitMessageFileName | Out-Null
		popd 
	}
}

# If directories names have changed case over the course of the TFS lifetime, you will run into HUGE problems
# with git. The symptoms are that some files appear in the file structure but Git appears to not be aware of them.
#
# This function addresses it by looking at the change log and asking Git about each file. If Git doesn't know 
# about the file it asks Windows (who is insensitive to case) what the file name is and tells Git to rename it.
function FixCaseSensitivity([string]$fileName) {
	$commitMessage = Get-Content $fileName | foreach { [regex]::Split($_, "`r`n") } | foreach {
		$pattern = $TFSRepository.Replace("$","[$]") + "/(.*)"
		if ($_ -match $pattern) { 
			if ([string]::IsNullOrEmpty($(git ls-files $matches[1] | Out-String))) {
				$realName = ls $matches[1] | Out-String
				git mv $matches[1] $realName
				Write-Host "Renamed file to" $realName
			}
		}
	}
}

# Retrieve the commit message for a specific changeset
function GetCommitMessage ([string]$ChangeSet, [string]$CommitMessageFileName)
{	
	tf changeset $ChangeSet /noprompt | Out-File $CommitMessageFileName -encoding utf8
}

# Clone the repository to the directory where you started the script.
function CloneToLocalBareRepository
{
	$TemporaryDirectory = GetTemporaryDirectory

	# If for some reason, old clone already exists, we remove it.
	if (Test-Path $GitRepository)
	{
		remove-item -path $GitRepository -force -recurse		
	}
	git clone --bare $TemporaryDirectory $GitRepository
	$(Get-Item -force $GitRepository).Attributes = "Normal"
	Write-Host "Your converted (bare) repository can be found in the" $GitRepository "directory."
}

# Clean up leftover directories and files.
function CleanUp
{
	$TempDir = GetTemporaryDirectory

	Write-Host "Removing workspace"
	tf workspace /delete $WorkspaceName /noprompt

	Write-Host "Removing working directories in" $TempDir
	Remove-Item -path $TempDir -force -recurse

	# Remove history file
	Remove-Item "history.txt"
}

function Main
{
	PrepareWorkspace
	Convert(GetChangesetsFromHistory)
	CloneToLocalBareRepository
	CleanUp

	Write-Host "Done!"
}

Main
