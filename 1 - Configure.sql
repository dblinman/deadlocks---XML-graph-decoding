-- Step 1: Configure 'blocked process threshold'
use master
go

sp_configure 'show advanced options', 1
go
reconfigure
go

sp_configure 'blocked process threshold (s)',20
go
reconfigure
go