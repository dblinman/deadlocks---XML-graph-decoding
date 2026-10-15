-- Step 3: Test XE Session --
if object_id('DeadlockTest') is not null 
begin
    drop table DeadlockTest;
end	

create table DeadlockTest (id int)
go
insert into DeadlockTest
select 1 
union all
select 2
go

-- 1st session
begin tran
	update DeadlockTest 
	set id = 22
	where id = 2

	waitfor delay '00:00:15'		

	update DeadlockTest 
	set id = 11
	where id = 1
commit

		/* -- 2nd session (Open new q-ry in SSMS)
		begin tran
			update DeadlockTest 
			set id = 111
			where id = 1

			waitfor delay '00:00:15'

			update DeadlockTest 
			set id = 222
			where id = 2
		commit
		*/


/* -- Blocking processes Test
IF object_id('BlockingTest') IS NOT NULL 
begin
    drop table  BlockingTest;
end	

create table BlockingTest (mycol int)
go
insert BlockingTest (mycol) VALUES(1)
go

--  Connection "A"
begin tran
 update BlockingTest 
 set mycol = 3
 
 waitfor delay '00:00:30'
commit
--rollback
	

	-- Connection "B" (Open new q-ry in SSMS)
	select * from BlockingTest
*/