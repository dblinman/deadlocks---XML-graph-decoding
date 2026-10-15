-- Step 5: Drop Event Session --
alter event session [XE_Blocked_process] on server state = stop
go
drop event session [XE_Blocked_process] on server
go
