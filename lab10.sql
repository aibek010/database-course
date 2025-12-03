# laboratory work №10  
 sql transactions and isolation levels  

 1. objective  
to study database transactions, understand acid properties, learn to use commit, rollback, and savepoint, and explore transaction isolation levels in sql.  

 2. theoretical background  

2.1 what is a transaction?  
a transaction is a sequence of sql operations executed as a single logical unit of work.  

 2.2 acid properties  

| property    | description    |
|---|---|
| atomic    | all operations succeed or all fail.    |
| consistent  | database moves from one valid state to another.    |
| isolated    | appears as if only one process executes at a time.    |
| durable     | changes persist after a system crash.    |

 2.3 transaction control statements  
begin – starts a transaction.  
commit – makes changes permanent.  
rollback – undoes changes since begin.  
savepoint – creates a point for partial rollback.  
rollback to savepoint_name** – rolls back to a savepoint.  
release savepoint – removes a savepoint.  

 2.4 isolation levels  

| level             | description                                      | phenomena allowed                     |
|-------------------|--------------------------------------------------|---------------------------------------|
| serializable      | highest isolation, serial execution              | none                                  |
| repeatable read   | prevents non-repeatable reads                    | phantom reads                         |
| read committed    | sees only committed data                         | non-repeatable reads, phantoms        |
| read uncommitted  | sees uncommitted changes                         | dirty reads, non-repeatable, phantoms |

setting isolation level:  
`set transaction isolation level serializable;`  
or within begin:  
`begin transaction isolation level repeatable read;`  

 3. practical tasks  

 3.1 setup: create test database  

create table accounts (  
    id serial primary key,  
    name varchar(100) not null,  
    balance decimal(10, 2) default 0.00  
);  

create table products (  
    id serial primary key,  
    shop varchar(100) not null,  
    product varchar(100) not null,  
    price decimal(10, 2) not null  
);  

insert into accounts (name, balance) values  
    ('alice', 1000.00),  
    ('bob', 500.00),  
    ('wally', 750.00);  

insert into products (shop, product, price) values  
    ('joe''s shop', 'coke', 2.50),  
    ('joe''s shop', 'pepsi', 3.00);  

 3.2 task 1: basic transaction with commit  

begin;  
update accounts set balance = balance - 100.00 where name = 'alice';  
update accounts set balance = balance + 100.00 where name = 'bob';  
commit;  

questions:
a) alice: 900.00, bob: 600.00  
b) ensures both updates succeed or fail together, preserving consistency.  
c) without a transaction, the database could be left in an inconsistent state.  

 3.3 task 2: using rollback  

begin;  
update accounts set balance = balance - 500.00 where name = 'alice';  
select * from accounts where name = 'alice';  
rollback;  
select * from accounts where name = 'alice';  

**questions:**  
a) 500.00  
b) 1000.00  
c) when an error occurs or a condition is not met.  


 3.4 task 3: working with savepoints  

begin;  
update accounts set balance = balance - 100.00 where name = 'alice';  
savepoint my_savepoint;  
update accounts set balance = balance + 100.00 where name = 'bob';  
rollback to my_savepoint;  
update accounts set balance = balance + 100.00 where name = 'wally';  
commit;  

questions:
a) alice: 900.00, bob: 500.00, wally: 850.00  
b) no, because the rollback undid the update to bob.  
c) allows partial rollback without ending the transaction.  

 3.5 task 4: isolation level demonstration  

scenario a: read committed**  

terminal 1:  

begin transaction isolation level read committed;  
select * from products where shop = 'joe''s shop';  
select * from products where shop = 'joe''s shop';  
commit;  

terminal 2:  

begin;  
delete from products where shop = 'joe''s shop';  
insert into products (shop, product, price) values ('joe''s shop', 'fanta', 3.50);  
commit;  

scenario b: serializable 

terminal 1:  

begin transaction isolation level serializable;  
select * from products where shop = 'joe''s shop';  
select * from products where shop = 'joe''s shop';  
commit;  

terminal 2: same as above.  

questions:
a) terminal 1 sees original data before commit, new data after commit.  
b) terminal 1 sees only original data throughout.  
c) read committed allows seeing committed changes from others; serializable isolates completely.  

 3.6 task 5: phantom read demonstration  

terminal 1:  

begin transaction isolation level repeatable read;  
select max(price), min(price) from products where shop = 'joe''s shop';  
select max(price), min(price) from products where shop = 'joe''s shop';  
commit;  

terminal 2:  

begin;  
insert into products (shop, product, price) values ('joe''s shop', 'sprite', 4.00);  
commit;  

questions:
a) no  
b) a phantom read occurs when new rows appear in subsequent reads.  
c) serializable  

 3.7 task 6: dirty read demonstration  

terminal 1:  

begin transaction isolation level read uncommitted;  
select * from products where shop = 'joe''s shop';  
select * from products where shop = 'joe''s shop';  
select * from products where shop = 'joe''s shop';  
commit;  

terminal 2:  

begin;  
update products set price = 99.99 where product = 'fanta';  
rollback;  

questions:
a) yes, it saw the uncommitted change, which is problematic because it was rolled back.  
b) a dirty read is reading uncommitted data that may be rolled back.  
c) it can lead to inconsistent and incorrect data.  

 4. independent exercises  

 exercise 1  
write a transaction that transfers $200 from bob to wally, but only if bob has sufficient funds.  

 exercise 2  
create a transaction with multiple savepoints that inserts, updates, deletes, and rolls back partially.  


design a banking scenario with concurrent withdrawals and demonstrate isolation level effects.  

 exercise 4  
demonstrate the max < min problem with sells(shop, product, price) and show how transactions fix it.  

 5. questions for self-assessment  
1. explain acid properties with examples.  
2. difference between commit and rollback.  
3. when to use savepoint vs. rollback.  
4. compare isolation levels.  
5. what is a dirty read and which level allows it?  
6. what is a non-repeatable read? example.  
7. what is a phantom read? which levels prevent it?  
8. why choose read committed over serializable?  
9. how do transactions maintain consistency?  
10. what happens to uncommitted changes after a crash?  


 6. lab report requirements  
include:  
- screenshots of sql commands and outputs  
- answers to all questions  
- solutions to independent exercises  
- answers to self-assessment questions  
- conclusion summarizing learning  

7. references  
1. postgresql documentation: transaction isolation  
2. sql standard: iso/iec 9075 - transaction processing  
3. database systems: the complete book by garcia-molina, ullman, and widom