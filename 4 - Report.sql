-- Step 4: Report --

/*
select
        object_name,
        file_name,
        file_offset,
        event_data,
        CAST(event_data AS XML) AS [Event_Data_XML]
    from
        sys.fn_xe_file_target_read_file( N'XE_Blocked_process*.xel', NULL, NULL, NULL )
	--where event_data like '%2026-10-15%' 
	--and event_data like '%MERGE%'
go

-- With Translated Datetime, report types
SELECT
    xevents.event_data,
    DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP), xevents.event_data.value('(event/@timestamp)[1]', 'datetime2')) AS [event time],
    xevents.event_data.query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph,
    xevents.event_data.query('(event[@name="blocked_process_report"]/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS blocked_process_report
FROM sys.fn_xe_file_target_read_file (N'XE_Blocked_process*.xel', NULL, NULL, NULL)
CROSS APPLY (SELECT CAST(event_data AS XML) AS event_data) as xevents
WHERE DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP), xevents.event_data.value('(event/@timestamp)[1]', 'datetime2')) >= dateadd(dd, datediff(dd,0,getdate()), 0) -- since Midnight
ORDER BY 2 DESC
go

-- Count by date
with events_cte as (
    select
    xevents.event_data,
    DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP), xevents.event_data.value('(event/@timestamp)[1]', 'datetime2')) AS [event time],
    xevents.event_data.query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
    from sys.fn_xe_file_target_read_file (N'XE_Blocked_process*.xel', NULL, NULL, NULL)
    cross apply (select cast(event_data AS XML) AS event_data) as xevents
)
select [Date], [ReportType], count(*) [Count]
from (
      select case when [deadlock_graph].exist('*') = 1 then 'Deadlock' else 'Blocked Process' end as ReportType,
      convert(nvarchar(50),DATEADD(dd,0,DATEDIFF(dd,0,[event time])),110) as [Date]
      from events_cte
      ) t
group by [Date],[ReportType]
union all
select NULL, '-- Total: --', count(*)
from events_cte
order by 1 desc,2
go

-- Count dealocks by hour since midnight
with events_cte AS (
    select
    xevents.event_data,
    dateadd(mi, datediff(mi, getutcdate(), current_timestamp), xevents.event_data.value('(event/@timestamp)[1]', 'datetime2')) AS [event time],
    xevents.event_data.query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
    from sys.fn_xe_file_target_read_file (N'XE_Blocked_process*.xel', NULL, NULL, NULL)
    cross apply (SELECT CAST(event_data AS XML) AS event_data) as xevents
)
select [ReportType], [Hour1], [Hour2], count(*) [Count]
from (
	select case when [deadlock_graph].exist('*') = 1 then 'Deadlock' else 'Blocked Process' end as [ReportType],
	datepart(hh,[event time]) as [Hour1], -- for sorting
    convert(varchar(5), datepart(hh,[event time]), 108) +  (case when datepart(hour, [event time]) >= 12 then ' PM' else ' AM' end) as [Hour2]
	from events_cte
	where [event time] >= dateadd(dd, datediff(dd,0,getdate()), 0) -- since Midnight
		and [deadlock_graph].exist('*') = 1
	) t
group by [ReportType], [Hour1], [Hour2]
union all
select '-- Total: --', 25, NULL, count(*)
from events_cte
where [event time] > = dateadd(dd, datediff(dd,0,getdate()), 0) -- since Midnight
	and [deadlock_graph].exist('*') = 1
order by [Hour1], [ReportType]
go
*/

-- FULL REPORT
set nocount on

if object_id('tempdb..#tDeadlocks')		is not null drop table #tDeadlocks;
if object_id('tempdb..#t')				is not null drop table #t;

declare @d int = 0;						-- Days to process

WITH events_cte AS (
	SELECT
		xevents.event_data [event_data],
		DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP), xevents.event_data.value('(event/@timestamp)[1]', 'datetime')) AS [timestamp],
		xevents.event_data.value('(event/@name)[1]', 'nvarchar(MAX)') AS [name]
	FROM sys.fn_xe_file_target_read_file (N'XE_Blocked_process*.xel', NULL, NULL, NULL)
	--FROM sys.fn_xe_file_target_read_file (N'system_health*.xel', NULL, NULL, NULL)
	CROSS APPLY (SELECT CAST(event_data AS XML) AS event_data) as [xevents]
	WHERE xevents.event_data.value('(event/@name)[1]', 'nvarchar(MAX)') = 'xml_deadlock_report'
			and DATEADD(mi, DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP), xevents.event_data.value('(event/@timestamp)[1]', 'datetime')) >= dateadd(dd, datediff(dd,@d,getdate()), 0) -- since Midnight
)
SELECT 
	 ROW_NUMBER() OVER(ORDER BY [timestamp]) AS [Row]
	,[event_data]
	,[name]
	,[timestamp]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)') AS [VictimProcess]
	-- process-list
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/@waitresource)[1]', 'nvarchar(50)') AS [waitresource1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/@waitresource)[2]', 'nvarchar(50)') AS [waitresource2]
	,NULL as [object_name1]
	,NULL as [object_name2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@waittime)[1]', 'nvarchar(50)')/1000 AS [waittime1(secs)]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@waittime)[1]', 'nvarchar(50)')/1000 AS [waittime2(secs)]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@id)[1]', 'nvarchar(100)') AS [process_id1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@id)[1]', 'nvarchar(100)') AS [process_id2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@transactionname)[1]', 'nvarchar(100)') AS [transactionname1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@transactionname)[1]', 'nvarchar(100)') AS [transactionname2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@lockMode)[1]', 'nvarchar(100)') AS [lockMode1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@lockMode)[1]', 'nvarchar(100)') AS [lockMode2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@schedulerid)[1]', 'nvarchar(100)') AS [schedulerid1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@schedulerid)[1]', 'nvarchar(100)') AS [schedulerid2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@status)[1]', 'nvarchar(100)') AS [status1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@status)[1]', 'nvarchar(100)') AS [status2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@spid)[1]', 'nvarchar(100)') AS [spid1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@spid)[1]', 'nvarchar(100)') AS [spid2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@priority)[1]', 'nvarchar(100)') AS [priority1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@priority)[1]', 'nvarchar(100)') AS [priority2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@trancount)[1]', 'nvarchar(100)') AS [trancount1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@trancount)[1]', 'nvarchar(100)') AS [trancount2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@lastbatchstarted)[1]', 'nvarchar(100)') AS [lastbatchstarted1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@lastbatchstarted)[1]', 'nvarchar(100)') AS [lastbatchstarted2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@lastbatchcompleted)[1]', 'nvarchar(100)') AS [lastbatchcompleted1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@lastbatchcompleted)[1]', 'nvarchar(100)') AS [lastbatchcompleted2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@clientapp)[1]', 'nvarchar(100)') AS [clientapp1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@clientapp)[1]', 'nvarchar(100)') AS [clientapp2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@hostname)[1]', 'nvarchar(100)') AS [hostname1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@hostname)[1]', 'nvarchar(100)') AS [hostname2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@loginname)[1]', 'nvarchar(100)') AS [loginname1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@loginname)[1]', 'nvarchar(100)') AS [loginname2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@isolationlevel)[1]', 'nvarchar(100)') AS [isolationlevel1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@isolationlevel)[1]', 'nvarchar(100)') AS [isolationlevel2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@currentdbname)[1]', 'nvarchar(100)') AS [currentdbname1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@currentdbname)[1]', 'nvarchar(100)') AS [currentdbname2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@lockTimeout)[1]', 'nvarchar(100)') AS [lockTimeout1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@lockTimeout)[1]', 'nvarchar(100)') AS [lockTimeout2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@clientoption1)[1]', 'nvarchar(100)') AS [clientoption1_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@clientoption2)[1]', 'nvarchar(100)') AS [clientoption2_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@clientoption1)[1]', 'nvarchar(100)') AS [clientoption1_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@clientoption2)[1]', 'nvarchar(100)') AS [clientoption2_2]
	--,case (select ( event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process/@clientoption2)[1]', 'nvarchar(100)') & 2 ) ) when 2 then 'YES' else 'NO' end AS [SET IMPLICIT_TRANSACTIONS ON]
	,replace(event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/executionStack/frame/@procname)[1]', 'nvarchar(100)'),
			 event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/@currentdbname)[1]', 'nvarchar(100)') + '.','') AS [procname1]
	,replace(event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/executionStack/frame/@procname)[1]', 'nvarchar(100)'),
			 event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/@currentdbname)[1]', 'nvarchar(100)') + '.','') AS [procname2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/executionStack/frame/@sqlhandle)[1]', 'nvarchar(100)') AS [sqlhandle1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/executionStack/frame/@sqlhandle)[1]', 'nvarchar(100)') AS [sqlhandle2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/executionStack/frame)[1]', 'sysname') AS [frame_sql_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/executionStack/frame)[1]', 'sysname') AS [frame_sql_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[1]/inputbuf)[1]', 'nvarchar(1024)') AS [inputbuf1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/process-list/process[2]/inputbuf)[1]', 'nvarchar(1024)') AS [inputbuf2]
	-- resource_list/keylock
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/@hobtid)[1]', 'nvarchar(100)') AS [keylock_hobtid_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/@hobtid)[1]', 'nvarchar(100)') AS [keylock_hobtid_2]
	,db_name(event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/@dbid)[1]', 'nvarchar(100)')) AS [keylock_dbname_1]
	,db_name(event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/@dbid)[1]', 'nvarchar(100)')) AS [keylock_dbname_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/@objectname)[1]', 'nvarchar(100)') AS [keylock_objectname_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/@objectname)[1]', 'nvarchar(100)') AS [keylock_objectname_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/@indexname)[1]', 'nvarchar(100)') AS [keylock_indexname_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/@indexname)[1]', 'nvarchar(100)') AS [keylock_indexname_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/owner-list/owner/@id)[1]', 'nvarchar(100)') AS [keylock_owner_id_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/owner-list/owner/@id)[1]', 'nvarchar(100)') AS [keylock_owner_id_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/owner-list/owner/@mode)[1]', 'nvarchar(100)') AS [keylock_owner_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/owner-list/owner/@mode)[1]', 'nvarchar(100)') AS [keylock_owner_mode_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/waiter-list/waiter/@mode)[1]', 'nvarchar(100)') AS [keylock_waiter_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/waiter-list/waiter/@mode)[1]', 'nvarchar(100)') AS [keylock_waiter_mode_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[1]/waiter-list/waiter/@requestType)[1]', 'nvarchar(100)') AS [keylock_requestType_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/keylock[2]/waiter-list/waiter/@requestType)[1]', 'nvarchar(100)') AS [keylock_requestType_2]
	-- resource_list/pagelock
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/@pageid)[1]', 'nvarchar(100)') AS [pagelock_pageid_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/@pageid)[1]', 'nvarchar(100)') AS [pagelock_pageid_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/@dbid)[1]', 'nvarchar(100)') AS [page_dbid_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/@dbid)[1]', 'nvarchar(100)') AS [page_dbid_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/@objectname)[1]', 'nvarchar(100)') AS [pagelock_objectname_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/@objectname)[1]', 'nvarchar(100)') AS [pagelock_objectname_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/@mode)[1]', 'nvarchar(100)') AS [pagelock_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/@mode)[1]', 'nvarchar(100)') AS [pagelock_mode_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/owner-list/owner/@id)[1]', 'nvarchar(100)') AS [pagelock_owner_id_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/owner-list/owner/@id)[1]', 'nvarchar(100)') AS [pagelock_owner_id_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/owner-list/owner/@mode)[1]', 'nvarchar(100)') AS [pagelock_owner_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/owner-list/owner/@mode)[1]', 'nvarchar(100)') AS [pagelock_owner_mode_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/waiter-list/waiter/@mode)[1]', 'nvarchar(100)') AS [pagelock_waiter_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/waiter-list/waiter/@mode)[1]', 'nvarchar(100)') AS [pagelock_waiter_mode_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[1]/waiter-list/waiter/@requestType)[1]', 'nvarchar(100)') AS [pagelock_waiter_requestType_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/pagelock[2]/waiter-list/waiter/@requestType)[1]', 'nvarchar(100)') AS [pagelock_waiter_requestType_2]
	-- resource_list/objectlock
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@lockPartition)[1]', 'nvarchar(100)') AS [objectlock_lockPartition_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@lockPartition)[2]', 'nvarchar(100)') AS [objectlock_lockPartition_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@dbid)[1]', 'nvarchar(100)') AS [objectlock_dbid_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@dbid)[2]', 'nvarchar(100)') AS [objectlock_dbid_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@objid)[1]', 'nvarchar(100)') AS [objectlock_objid_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@objid)[2]', 'nvarchar(100)') AS [objectlock_objid_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@objectname)[1]', 'nvarchar(100)') AS [objectlock_objectname_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@objectname)[2]', 'nvarchar(100)') AS [objectlock_objectname_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@mode)[1]', 'nvarchar(100)') AS [objectlock_mode_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/objectlock/@mode)[2]', 'nvarchar(100)') AS [objectlock_mode_2]
	-- resource_list/exchangeEvent
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@WaitType)[1]', 'nvarchar(100)') AS [exchangeEvent_WaitType_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@WaitType)[2]', 'nvarchar(100)') AS [exchangeEvent_WaitType_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waiterType)[1]', 'nvarchar(100)') AS [exchangeEvent_waiterType_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waiterType)[2]', 'nvarchar(100)') AS [exchangeEvent_waiterType_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waiterActivity)[1]', 'nvarchar(100)') AS [exchangeEvent_waiterActivity_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waiterActivity)[2]', 'nvarchar(100)') AS [exchangeEvent_waiterActivity_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@merging)[1]', 'nvarchar(100)') AS [exchangeEvent_merging_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@merging)[2]', 'nvarchar(100)') AS [exchangeEvent_merging_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@spilling)[1]', 'nvarchar(100)') AS [exchangeEvent_spilling_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@spilling)[2]', 'nvarchar(100)') AS [exchangeEvent_spilling_2]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waitingToClose)[1]', 'nvarchar(100)') AS [exchangeEvent_waitingToClose_1]
	,event_data.value('(event/data[@name="xml_report"]/value/deadlock/resource-list/exchangeEvent/@waitingToClose)[2]', 'nvarchar(100)') AS [exchangeEvent_waitingToClose_2]
into #tDeadlocks
FROM events_cte
option(maxdop 8);

ALTER TABLE #tDeadlocks ALTER column [Row] int NOT NULL; 
ALTER TABLE #tDeadlocks ADD PRIMARY KEY CLUSTERED (Row); 

-- change data type to sysname
ALTER TABLE #tDeadlocks ALTER column [object_name1] varchar(255) NULL; 
ALTER TABLE #tDeadlocks ALTER column [object_name2] varchar(255) NULL; 

/*
select *
	--,IIF([clientoption1_1] & 2 = 2, 'ON', 'OFF') [clientoption1_1_implicit]
	--,IIF([clientoption2_1] & 2 = 2, 'ON', 'OFF') [clientoption2_1_implicit]
	--,IIF([clientoption1_2] & 2 = 2, 'ON', 'OFF') [clientoption1_2_implicit]
	--,IIF([clientoption2_2] & 2 = 2, 'ON', 'OFF') [clientoption2_2_implicit]
from #tDeadlocks 
order by [timestamp] desc
*/

-- get waiter info for PAGE
declare @Row						int,
		@waitresource1				sysname,
		@waitresource2				sysname,
		@waitresource1_Type			sysname,
		@waitresource1_4			nvarchar(25),
		@waitresource1_3			nvarchar(25),
		@waitresource1_2			nvarchar(25),
		@waitresource1_1			nvarchar(25),
		--@waitresource2_lockres		sysname,				-- Locate a record: SELECT * FROM boards.GOAL (NOLOCK) WHERE %%lockres%% = '(b94868db738d)'
		@waitresource2_Type			sysname,
		@waitresource2_4			nvarchar(25),
		@waitresource2_3			nvarchar(25),
		@waitresource2_2			nvarchar(25),
		@waitresource2_1			nvarchar(25),
		--@waitresource1_lockres		sysname,				
		@cmd						varchar(MAX)

if object_id('tempdb..#t')				is not null drop table #t;
create table #t ([ParentObject] sysname NULL, [Object] sysname NULL, [Field] sysname NULL, [Value] nvarchar(100) NULL, [object_name1] varchar(255) NULL, [object_name2] varchar(255) NULL)
declare Deadlock_cursor cursor 
						for
							-- Decoding: https://www.littlekendra.com/2016/10/17/decoding-key-and-page-waitresource-for-deadlocks-and-blocking/
							select
								[Row], 
								[waitresource1],
								[waitresource2],
								left(waitresource1, CHARINDEX(':',waitresource1) - 1) [waitresource1_type],
								parsename(replace(replace(substring([waitresource1],CHARINDEX(':',[waitresource1]) + 1, 50),':','.'), '(','.'),4) [waitresource1_4],
								parsename(replace(replace(substring([waitresource1],CHARINDEX(':',[waitresource1]) + 1, 50),':','.'), '(','.'),3) [waitresource1_3],
								parsename(replace(replace(substring([waitresource1],CHARINDEX(':',[waitresource1]) + 1, 50),':','.'), '(','.'),2) [waitresource1_2],
								parsename(replace(replace(replace(substring([waitresource1],CHARINDEX(':',[waitresource1]) + 1, 50),':','.'),'(','.'), ')',''),1) [waitresource1_1],
								left(waitresource2, CHARINDEX(':',waitresource2) - 1) [waitresource2_type],
								parsename(replace(replace(substring([waitresource2],CHARINDEX(':',[waitresource2]) + 1, 50),':','.'), '(','.'),4) [waitresource2_4],
								parsename(replace(replace(substring([waitresource2],CHARINDEX(':',[waitresource2]) + 1, 50),':','.'), '(','.'),3) [waitresource2_3],
								parsename(replace(replace(substring([waitresource2],CHARINDEX(':',[waitresource2]) + 1, 50),':','.'), '(','.'),2) [waitresource2_2],
								parsename(replace(replace(replace(substring([waitresource2],CHARINDEX(':',[waitresource2]) + 1, 50),':','.'),'(','.'), ')',''),1) [waitresource2_1]
							from #tDeadlocks 
							where [timestamp] >= dateadd(dd, datediff(dd,@d,getdate()), 0) -- since Midnight
							order by 1 desc
							for update of object_name1,object_name2;
open Deadlock_cursor
fetch next from Deadlock_cursor into @Row,
									 @waitresource1,@waitresource2,@waitresource1_Type,@waitresource1_4,@waitresource1_3,@waitresource1_2,@waitresource1_1,
									 @waitresource2_Type,@waitresource2_4,@waitresource2_3,@waitresource2_2,@waitresource2_1
while (@@fetch_status = 0)
begin
	--select @Row,
	--		@waitresource1,@waitresource2,@waitresource1_Type,@waitresource1_4,@waitresource1_3,@waitresource1_2,@waitresource1_1,
	--		@waitresource2_Type,@waitresource2_4,@waitresource2_3,@waitresource2_2,@waitresource2_1

			-- waitresource_1
			IF @waitresource1_Type = 'OBJECT'
			BEGIN
				set @cmd = '
				INSERT INTO #t ([object_name1])
				SELECT s.name + ''.'' + o.name
					FROM ' + db_name(@waitresource1_3) + '.sys.objects o
					JOIN ' + db_name(@waitresource1_3) + '.sys.schemas s ON s.schema_id=o.schema_id
					WHERE o.object_id = ' + @waitresource1_2
				exec (@cmd)
			END

			IF @waitresource1_Type = 'PAGE'
			BEGIN
				set @cmd = 'dbcc page (' + @waitresource1_3 + ',' + @waitresource1_2 + ',' + @waitresource1_1 + ') with no_infomsgs, tableresults'
				insert into #t ([ParentObject], [Object], [Field], [Value])
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name1] = (
					SELECT s.name + ''.'' + o.name + ''.'' + i.name
					FROM ' + db_name(@waitresource1_3) + '.sys.partitions p
					JOIN ' + db_name(@waitresource1_3) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource1_3) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource1_3) + '.sys.schemas s ON s.schema_id = o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = [value] )
				where [Field] = ''Metadata: PartitionId'' '
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name1] = (
					select [name] from ' + db_name(@waitresource1_3) + '.sys.indexes where [object_id] = ' + (select [value] from #t where [Field] = 'Metadata: ObjectId') + ' and index_id = [value] )
				where [Field] = ''Metadata: IndexId'' '
				exec (@cmd)

				update #t
				set [object_name1] = object_name([value], @waitresource1_3)
				where [Field] = 'Metadata: ObjectId'
			END

			IF @waitresource1_Type = 'RID'
			BEGIN
				set @cmd = 'dbcc page (' + @waitresource1_4 + ',' + @waitresource1_3 + ',' + @waitresource1_2 + ') with no_infomsgs, tableresults'
				insert into #t ([ParentObject], [Object], [Field], [Value])
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name1] = (
					SELECT s.name + ''.'' + o.name + ISNULL(''.'' + i.name,'''')
					FROM ' + db_name(@waitresource1_4) + '.sys.partitions p
					JOIN ' + db_name(@waitresource1_4) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource1_4) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource1_4) + '.sys.schemas s ON s.schema_id=o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = [value] )
				where [Field] = ''Metadata: PartitionId'' '
				--print @cmd
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name1] = (
					select [name] from ' + db_name(@waitresource1_4) + '.sys.indexes where [object_id] = ' + (select [value] from #t where [Field] = 'Metadata: ObjectId') + ' and index_id = [value] )
				where [Field] = ''Metadata: IndexId'' '
				--print @cmd
				exec (@cmd)

				update #t
				set [object_name1] = object_name([value], @waitresource1_4)
				where [Field] = 'Metadata: ObjectId'
			END

			IF @waitresource1_Type = 'KEY'
			BEGIN
				set @cmd = '
				INSERT INTO #t ([object_name1])
				SELECT s.name + ''.'' + o.name + ''.'' + i.name
					FROM ' + db_name(@waitresource1_3) + '.sys.partitions p
					JOIN ' + db_name(@waitresource1_3) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource1_3) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource1_3) + '.sys.schemas s ON s.schema_id = o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = ' + @waitresource1_2
				--print @cmd
				exec (@cmd)
			END

			-- update cursor
			UPDATE #tDeadlocks
			SET [object_name1] =
				case @waitresource1_Type 
					WHEN 'OBJECT'
						then (select object_name1 from #t)
					WHEN 'PAGE'
						then ISNULL((select object_name1 from #t where [Field] = 'Metadata: PartitionId'),(select object_name1 from #t where [Field] = 'Metadata: ObjectId'))
					WHEN 'RID'
						then ISNULL((select object_name1 from #t where [Field] = 'Metadata: PartitionId'),(select object_name1 from #t where [Field] = 'Metadata: ObjectId'))
					WHEN 'KEY'
						then (select object_name1 from #t)
				end
			WHERE CURRENT OF Deadlock_cursor  

			-- Check
			--select * from #t where object_name1 IS NOT NULL

			-- CleanUp
			DELETE FROM #t


			-- waitresource_2
			IF @waitresource2_Type = 'OBJECT'
			BEGIN
				set @cmd = '
				INSERT INTO #t ([object_name2])
				SELECT s.name + ''.'' + o.name
					FROM ' + db_name(@waitresource2_3) + '.sys.objects o
					JOIN ' + db_name(@waitresource2_3) + '.sys.schemas s ON s.schema_id=o.schema_id
					WHERE o.object_id = ' + @waitresource2_2
				exec (@cmd)
			END

			IF @waitresource2_Type = 'PAGE'
			BEGIN
				set @cmd = 'dbcc page (' + @waitresource2_3 + ',' + @waitresource2_2 + ',' + @waitresource2_1 + ') with no_infomsgs, tableresults'
				insert into #t ([ParentObject], [Object], [Field], [Value])
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name2] = (
					SELECT s.name + ''.'' + o.name + ''.'' + i.name
					FROM ' + db_name(@waitresource2_3) + '.sys.partitions p
					JOIN ' + db_name(@waitresource2_3) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.schemas s ON s.schema_id=o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = [value] )
				where [Field] = ''Metadata: PartitionId'' '
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name2] = (
					select [name] from ' + db_name(@waitresource2_3) + '.sys.indexes where [object_id] = ' + (select [value] from #t where [Field] = 'Metadata: ObjectId') + ' and index_id = [value] )
				where [Field] = ''Metadata: IndexId'' '
				exec (@cmd)

				update #t
				set [object_name2] = object_name([value], @waitresource2_3)
				where [Field] = 'Metadata: ObjectId'
			END

			IF @waitresource2_Type = 'RID'
			BEGIN
				set @cmd = 'dbcc page (' + @waitresource2_4 + ',' + @waitresource2_3 + ',' + @waitresource2_2 + ') with no_infomsgs, tableresults'
				insert into #t ([ParentObject], [Object], [Field], [Value])
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name2] = (
					SELECT s.name + ''.'' + o.name + ISNULL(''.'' + i.name,'''')
					FROM ' + db_name(@waitresource2_4) + '.sys.partitions p
					JOIN ' + db_name(@waitresource2_4) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource2_4) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource2_4) + '.sys.schemas s ON s.schema_id=o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = [value] )
				where [Field] = ''Metadata: PartitionId'' '
				exec (@cmd)

				set @cmd = '
				update #t
				set [object_name2] = (
					select [name] from ' + db_name(@waitresource2_4) + '.sys.indexes where [object_id] = ' + (select [value] from #t where [Field] = 'Metadata: ObjectId') + ' and index_id = [value] )
				where [Field] = ''Metadata: IndexId'' '
				exec (@cmd)

				update #t
				set [object_name2] = object_name([value], @waitresource2_4)
				where [Field] = 'Metadata: ObjectId'
			END

			IF @waitresource2_Type = 'KEY'
			BEGIN
				if exists ( select top 1 1 from #t )
				set @cmd = '
				update #t
				set [object_name2] = (
					SELECT s.name + ''.'' + o.name + ''.'' + i.name
					FROM ' + db_name(@waitresource2_3) + '.sys.partitions p
					JOIN ' + db_name(@waitresource2_3) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.schemas s ON s.schema_id=o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = ' + @waitresource2_2 + '
				)
				where [Field] = ''Metadata: PartitionId''	'
				else
				set @cmd = '
				insert #t ([object_name2])
					SELECT s.name + ''.'' + o.name + ''.'' + i.name
					FROM ' + db_name(@waitresource2_3) + '.sys.partitions p
					JOIN ' + db_name(@waitresource2_3) + '.sys.objects o ON p.[object_id] = o.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.indexes i ON p.[object_id] = i.[object_id]
					JOIN ' + db_name(@waitresource2_3) + '.sys.schemas s ON s.schema_id=o.schema_id
					AND p.index_id = i.index_id
					WHERE p.hobt_id = ' + @waitresource2_2
				exec (@cmd)
			END

			-- update cursor
			UPDATE #tDeadlocks
			SET [object_name2] = 
				case @waitresource2_Type 
					WHEN 'OBJECT'
						then (select object_name2 from #t)
					WHEN 'PAGE'
						then ISNULL((select object_name2 from #t where [Field] = 'Metadata: PartitionId'),(select object_name2 from #t where [Field] = 'Metadata: ObjectId'))
					WHEN 'RID'
						then ISNULL((select object_name2 from #t where [Field] = 'Metadata: PartitionId'),(select object_name2 from #t where [Field] = 'Metadata: ObjectId'))
					WHEN 'KEY'
						then (select object_name2 from #t)
				end
			WHERE CURRENT OF Deadlock_cursor 

			-- Check
			--select * from #t --where object_name2 IS NOT NULL

			-- CleanUp
			DELETE FROM #t

 fetch next from Deadlock_cursor into @Row,
									  @waitresource1,@waitresource2,@waitresource1_Type,@waitresource1_4,@waitresource1_3,@waitresource1_2,@waitresource1_1,
									  @waitresource2_Type,@waitresource2_4,@waitresource2_3,@waitresource2_2,@waitresource2_1
end
 close Deadlock_cursor
 deallocate Deadlock_cursor

SELECT 
	*
	,IIF([clientoption1_1] & 2 = 2, 'ON', 'OFF') [clientoption1_1_implicit]
	,IIF([clientoption2_1] & 2 = 2, 'ON', 'OFF') [clientoption2_1_implicit]
	,IIF([clientoption1_2] & 2 = 2, 'ON', 'OFF') [clientoption1_2_implicit]
	,IIF([clientoption2_2] & 2 = 2, 'ON', 'OFF') [clientoption2_2_implicit]
from #tDeadlocks
WHERE [timestamp] >= dateadd(dd, datediff(dd,@d,getdate()), 0) -- since Midnight
		and [Name] = 'xml_deadlock_report'
order by 1 desc

if object_id('tempdb..#tDeadlocks')		is not null drop table #tDeadlocks;
if object_id('tempdb..#t')				is not null drop table #t;