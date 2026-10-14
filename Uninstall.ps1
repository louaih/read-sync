$appDir = Join-Path $env:LOCALAPPDATA 'ReadingSync'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*ReadingSync.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'ReadingSync.vbs') -ErrorAction SilentlyContinue
Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Reading Sync removed. Your calibre library, PDFs and the progress folder were not touched.'
Read-Host 'Press Enter to close'
