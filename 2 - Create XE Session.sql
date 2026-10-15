-- Step 2: Create Event Session
CREATE EVENT SESSION [XE_Blocked_process] 
	ON SERVER
	ADD EVENT sqlserver.blocked_process_report(
		ACTION(sqlserver.client_app_name,
			   sqlserver.client_hostname,
			   sqlserver.database_name)) ,
	ADD EVENT sqlserver.xml_deadlock_report (
		ACTION(sqlserver.client_app_name,
			   sqlserver.client_hostname,
			   sqlserver.database_name))
	ADD TARGET package0.asynchronous_file_target
	(SET filename = N'XE_Blocked_process.xel',
		 --metadatafile = N'XE_Blocked_process.xem',	-- prior to 2012 
		 max_file_size=(65536),
		 max_rollover_files=5)
	WITH (MAX_MEMORY=4096 KB,
		  EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,
		  MAX_DISPATCH_LATENCY=5 SECONDS,
		  MAX_EVENT_SIZE=0 KB,
		  MEMORY_PARTITION_MODE=NONE,
		  TRACK_CAUSALITY=OFF,
		  STARTUP_STATE=ON)
GO

-- Start
alter event session [XE_Blocked_process] on server state = start;
go

-- Verify
select * 
from sys.server_event_sessions 
where name = 'XE_Blocked_process'