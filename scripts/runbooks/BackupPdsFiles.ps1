param(
  [Parameter(Mandatory=$true)]
  [string]$StorageAccountName,

  [Parameter(Mandatory=$true)]
  [string]$ShareName,

  [Parameter(Mandatory=$true)]
  [int]$RetentionDays,

  [Parameter(Mandatory=$true)]
  [string]$ResourceGroupName
)

Import-Module Az.Storage

Write-Output "Starting backup process for storage account: $StorageAccountName, share: $ShareName"

try {
  Connect-AzAccount -Identity

  $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
  $ctx = $storageAccount.Context

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $snapshotName = "backup-$timestamp"

  Write-Output "Creating snapshot: $snapshotName"
  $snapshot = New-AzStorageShare -Name $ShareName -Context $ctx -Snapshot

  Write-Output "Snapshot created: $($snapshot.SnapshotTime)"

  Write-Output "Cleaning up snapshots older than $RetentionDays days"
  $cutoffDate = (Get-Date).AddDays(-$RetentionDays)

  $allSnapshots = Get-AzStorageShare -Name $ShareName -Context $ctx -IncludeSnapshot
  $oldSnapshots = $allSnapshots | Where-Object { $_.IsSnapshot -and $_.SnapshotTime -lt $cutoffDate }

  foreach ($oldSnapshot in $oldSnapshots) {
    Write-Output "Removing old snapshot from: $($oldSnapshot.SnapshotTime)"
    Remove-AzStorageShare -Share $oldSnapshot -Force
  }

  Write-Output "Backup process completed successfully"
}
catch {
  Write-Error "Backup failed: $($_.Exception.Message)"
  throw
}

