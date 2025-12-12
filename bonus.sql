--task1: ddl tables
create table customers (
    customer_id serial primary key,
    tin char(12) unique not null,
    full_name text not null,
    phone text,
    email text,
    status text check (status in ('active','blocked','frozen')),
    daily_limit_kzt numeric(14,2) not null default 1000000,
    created_at timestamp default current_timestamp
);

create table accounts (
    account_id serial primary key,
    customer_id int references customers(customer_id),
    account_number text unique not null,
    currency char(3) check (currency in ('kzt','usd','eur','rub')),
    balance numeric(14,2) not null check (balance >= 0),
    is_active boolean default true,
    opened_at timestamp default current_timestamp,
    closed_at timestamp
);

create table exchange_rates (
    rate_id serial primary key,
    from_currency char(3),
    to_currency char(3),
    rate numeric(10,4),
    valid_from timestamp,
    valid_to timestamp
);

create table transactions (
    transaction_id serial primary key,
    from_account_id int references accounts(account_id),
    to_account_id int references accounts(account_id),
    amount numeric(14,2),
    currency char(3),
    exchange_rate numeric(10,4) default 1,
    amount_kzt numeric(14,2),
    to_amount numeric(14,2),
    to_currency char(3),
    type text check (type in ('transfer','deposit','withdrawal')),
    status text check (status in ('pending','completed','failed','reversed')),
    created_at timestamp default current_timestamp,
    completed_at timestamp,
    description text
);

create table audit_log (
    log_id serial primary key,
    table_name text,
    record_id int,
    action text check (action in ('insert','update','delete','failed','failed_batch','failed_deposit')),
    old_values jsonb,
    new_values jsonb,
    changed_by text,
    changed_at timestamp default current_timestamp,
    ip_address text
);

-- вспомогательная функция для логирования
create or replace function log_error_to_audit(
    p_table_name text,
    p_action text,
    p_error_code text,
    p_error_message text,
    p_data jsonb
) returns void
language plpgsql
security definer
as $$
begin
    insert into audit_log (
        table_name,
        action,
        new_values,
        changed_by,
        ip_address
    )
    values (
        p_table_name,
        p_action,
        jsonb_build_object(
            'error_code', p_error_code,
            'error_message', p_error_message,
            'data', p_data,
            'logged_at', current_timestamp
        ),
        current_user,
        inet_client_addr()
    );
exception
    when others then
        null;
end;
$$;

--task1: process_transfer
create or replace procedure process_transfer(
    p_from_account text,
    p_to_account text,
    p_amount numeric,
    p_currency char(3),
    p_description text default null,
    p_bypass_limit boolean default false,
    p_commit boolean default true
)
language plpgsql
as $$
declare
    v_from_id int;
    v_to_id int;
    v_from_customer_id int;
    v_to_customer_id int;
    v_from_balance numeric;
    v_from_currency char(3);
    v_to_currency char(3);
    v_limit numeric;
    v_today_sum numeric;
    v_rate_to_kzt numeric := 1;
    v_rate_to_receiver numeric := 1;
    v_amount_kzt numeric;
    v_amount_to_receiver numeric;
    v_error_code text;
    v_error_message text;
    v_transaction_id int;
begin
    if p_commit then
        start transaction;
    end if;

    select a.account_id, a.balance, a.currency, a.customer_id
    into v_from_id, v_from_balance, v_from_currency, v_from_customer_id
    from accounts a
    where a.account_number = p_from_account
      and a.is_active = true
    for update;

    if not found then
        v_error_code := 'tr001';
        v_error_message := 'счет отправителя не найден или неактивен';
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if p_currency <> v_from_currency then
        v_error_code := 'tr010';
        v_error_message := format('валюта перевода (%s) не соответствует валюте счета отправителя (%s)',
                                 p_currency, v_from_currency);
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if not exists (
        select 1 from customers
        where customer_id = v_from_customer_id
        and status = 'active'
    ) then
        v_error_code := 'tr002';
        v_error_message := 'клиент отправителя заблокирован или заморожен';
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    select a.account_id, a.currency, a.customer_id
    into v_to_id, v_to_currency, v_to_customer_id
    from accounts a
    where a.account_number = p_to_account
      and a.is_active = true
    for update;

    if not found then
        v_error_code := 'tr003';
        v_error_message := 'счет получателя не найден или неактивен';
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if v_from_id = v_to_id then
        v_error_code := 'tr004';
        v_error_message := 'нельзя переводить на тот же счет';
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if not exists (
        select 1 from customers
        where customer_id = v_to_customer_id
        and status = 'active'
    ) then
        v_error_code := 'tr005';
        v_error_message := 'клиент получателя заблокирован или заморожен';
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if v_from_currency <> 'kzt' then
        select rate
        into v_rate_to_kzt
        from exchange_rates
        where from_currency = v_from_currency
          and to_currency = 'kzt'
          and current_timestamp between valid_from and valid_to;

        if v_rate_to_kzt is null then
            v_error_code := 'tr006';
            v_error_message := format('курс валюты не найден (в kzt) для %s', v_from_currency);
            raise exception using
                errcode = v_error_code,
                message = v_error_message;
        end if;
    end if;

    v_amount_kzt := p_amount * v_rate_to_kzt;

    if v_from_currency <> v_to_currency then
        select rate
        into v_rate_to_receiver
        from exchange_rates
        where from_currency = v_from_currency
          and to_currency = v_to_currency
          and current_timestamp between valid_from and valid_to;

        if v_rate_to_receiver is null then
            v_error_code := 'tr009';
            v_error_message := format('курс конвертации не найден: %s -> %s',
                                     v_from_currency, v_to_currency);
            raise exception using
                errcode = v_error_code,
                message = v_error_message;
        end if;
    end if;

    v_amount_to_receiver := p_amount * v_rate_to_receiver;

    if not p_bypass_limit then
        select c.daily_limit_kzt
        into v_limit
        from customers c
        where c.customer_id = v_from_customer_id;

        select coalesce(sum(amount_kzt), 0)
        into v_today_sum
        from transactions t
        where t.from_account_id = v_from_id
          and t.status = 'completed'
          and date(t.created_at) = current_date
          and t.type = 'transfer';

        if v_today_sum + v_amount_kzt > v_limit then
            v_error_code := 'tr007';
            v_error_message := format('дневной лимит превышен: использовано %s, лимит %s (kzt)',
                                     v_today_sum + v_amount_kzt, v_limit);
            raise exception using
                errcode = v_error_code,
                message = v_error_message;
        end if;
    end if;

    if v_from_balance < p_amount then
        v_error_code := 'tr008';
        v_error_message := format('недостаточно средств: баланс %s %s, требуется %s %s',
                                 v_from_balance, v_from_currency, p_amount, v_from_currency);
        raise exception using
            errcode = v_error_code,
            message = v_error_message;
    end if;

    if p_commit then
        savepoint before_transfer;
    end if;

    update accounts
    set balance = balance - p_amount
    where account_id = v_from_id;

    update accounts
    set balance = balance + v_amount_to_receiver
    where account_id = v_to_id;

    insert into transactions (
        from_account_id, to_account_id, amount, currency, exchange_rate, amount_kzt,
        to_amount, to_currency, type, status, description, completed_at
    )
    values (
        v_from_id, v_to_id, p_amount, v_from_currency, v_rate_to_receiver, v_amount_kzt,
        v_amount_to_receiver, v_to_currency, 'transfer', 'completed', p_description, current_timestamp
    )
    returning transaction_id into v_transaction_id;

    insert into audit_log (table_name, record_id, action, new_values, changed_by, ip_address)
    values (
        'transactions',
        v_transaction_id,
        'insert',
        jsonb_build_object(
            'from_account', p_from_account, 'to_account', p_to_account, 'from_currency', v_from_currency,
            'to_currency', v_to_currency, 'sent_amount', p_amount, 'received_amount', v_amount_to_receiver,
            'exchange_rate', v_rate_to_receiver, 'amount_kzt', v_amount_kzt, 'description', p_description
        ),
        current_user,
        inet_client_addr()
    );

    if p_commit then
        commit;
    end if;

exception
    when others then
        get stacked diagnostics
            v_error_code = returned_sqlstate,
            v_error_message = message_text;

        perform log_error_to_audit(
            'transactions', 'failed', v_error_code, v_error_message,
            jsonb_build_object(
                'from_account', p_from_account, 'to_account', p_to_account, 'amount', p_amount,
                'currency', p_currency, 'attempted_at', current_timestamp, 'description', p_description
            )
        );

        if p_commit then
            rollback;
        end if;

        raise exception using
            errcode = v_error_code,
            message = v_error_message;
end;
$$;

--task4: process_salary_batch
create or replace procedure process_salary_batch(
    p_company_account text,
    p_payments jsonb,
    p_description text default 'salary payment'
)
language plpgsql
as $$
declare
    v_company_id int;
    v_company_balance numeric;
    v_company_currency char(3);
    v_total_amount numeric := 0;
    v_success_count int := 0;
    v_failed_count int := 0;
    v_failed_details jsonb := '[]'::jsonb;
    v_payment_record jsonb;
    v_error_code text;
    v_error_message text;
    v_total_successful_amount numeric := 0;
    v_batch_id text := 'batch_' || replace(cast(current_timestamp as text), ' ', '_');
    temp_payment_records record;
begin
    select a.account_id, a.balance, a.currency
    into v_company_id, v_company_balance, v_company_currency
    from accounts a
    where a.account_number = p_company_account
      and a.is_active = true
    for update;

    if not found then
        raise exception 'счет компании не найден или неактивен';
    end if;

   select sum((value ->>'amount')::numeric)
    into v_total_amount
    from jsonb_array_elements(p_payments);

    if v_total_amount is null then
        raise exception 'неверный формат платежей или пустой пакет';
    end if;

    if v_company_balance < v_total_amount then
        raise exception format('недостаточно средств на счете компании: баланс %s %s, требуется %s kzt',
                               v_company_balance, v_company_currency, v_total_amount);
    end if;

    perform pg_advisory_lock(hashtext(p_company_account));

    begin
        create temporary table successful_payments_temp (
            payment_id serial,
            target_account text,
            amount numeric,
            employee_iin text,
            description text,
            target_account_id int,
            target_currency char(3)
        ) on commit drop;

        for v_payment_record in
            select * from jsonb_array_elements(p_payments)
        loop
            declare
                v_target_account text;
                v_amount numeric;
                v_employee_iin text;
                v_payment_desc text;
                v_target_account_id int;
                v_target_currency char(3);
            begin
                v_target_account := v_payment_record->>'account';
                v_amount := (v_payment_record->>'amount')::numeric;
                v_employee_iin := v_payment_record->>'iin';
                v_payment_desc := coalesce(v_payment_record->>'description', p_description);

                savepoint salary_payment_validation;

                select account_id, currency
                into v_target_account_id, v_target_currency
                from accounts
                where account_number = v_target_account
                  and is_active = true;

                if not found then
                    raise exception 'счет получателя не найден или неактивен: %', v_target_account;
                end if;

                if not exists (
                    select 1 from customers c
                    join accounts a on a.customer_id = c.customer_id
                    where a.account_id = v_target_account_id
                      and c.status = 'active'
                ) then
                    raise exception 'клиент получателя неактивен: %', v_target_account;
                end if;

                if v_company_currency <> v_target_currency then
                    raise exception 'несоответствие валют счета компании (%s) и получателя (%s). пакетная выплата поддерживает только одну валюту.', v_company_currency, v_target_currency;
                end if;

                insert into successful_payments_temp
                (target_account, amount, employee_iin, description, target_account_id, target_currency)
                values
                (v_target_account, v_amount, v_employee_iin, v_payment_desc, v_target_account_id, v_target_currency);

                v_success_count := v_success_count + 1;

                release savepoint salary_payment_validation;
            exception
                when others then
                    get stacked diagnostics v_error_message = message_text;

                    rollback to savepoint salary_payment_validation;

                    v_failed_count := v_failed_count + 1;

                    v_failed_details := v_failed_details || jsonb_build_object(
                        'employee_iin', v_employee_iin,
                        'account', v_target_account,
                        'amount', v_amount,
                        'error', v_error_message
                    );
            end;
        end loop;

        select coalesce(sum(amount), 0)
        into v_total_successful_amount
        from successful_payments_temp;

        if v_total_successful_amount = 0 and v_failed_count > 0 then
             raise exception 'пакетная обработка завершена. все % платежей не удались: %', v_failed_count, v_failed_details;
        elsif v_total_successful_amount = 0 and v_failed_count = 0 then
             raise exception 'пакетная обработка прервана. неверный формат данных или пустой пакет.';
        end if;


        update accounts
        set balance = balance - v_total_successful_amount
        where account_id = v_company_id
        returning balance into v_company_balance;

        insert into transactions (
            from_account_id, to_account_id, amount, currency, amount_kzt, type, status, description, completed_at
        )
        values (
            v_company_id,
            null,
            v_total_successful_amount,
            v_company_currency,
            v_total_successful_amount,
            'withdrawal',
            'completed',
            p_description || ' (batch total)',
            current_timestamp
        );

        for temp_payment_records in
            select * from successful_payments_temp
        loop
            declare
                v_transaction_id int;
            begin
                update accounts
                set balance = balance + temp_payment_records.amount
                where account_id = temp_payment_records.target_account_id;

                insert into transactions (
                    from_account_id, to_account_id, amount, currency, amount_kzt, to_amount, to_currency, type, status, description, completed_at
                )
                values (
                    v_company_id,
                    temp_payment_records.target_account_id,
                    temp_payment_records.amount,
                    v_company_currency,
                    temp_payment_records.amount,
                    temp_payment_records.amount,
                    temp_payment_records.target_currency,
                    'deposit',
                    'completed',
                    p_description || ' - ' || coalesce(temp_payment_records.description, 'salary'),
                    current_timestamp
                )
                returning transaction_id into v_transaction_id;

                insert into audit_log (table_name, record_id, action, new_values, changed_by, ip_address)
                values (
                    'transactions',
                    v_transaction_id,
                    'insert',
                    jsonb_build_object(
                        'batch_id', v_batch_id, 'company_account', p_company_account,
                        'employee_account', temp_payment_records.target_account, 'amount', temp_payment_records.amount,
                        'employee_iin', temp_payment_records.employee_iin, 'description', temp_payment_records.description
                    ),
                    current_user,
                    inet_client_addr()
                );

            exception
                when others then
                    get stacked diagnostics v_error_message = message_text;

                    v_failed_count := v_failed_count + 1;
                    v_success_count := v_success_count - 1;

                    v_failed_details := v_failed_details || jsonb_build_object(
                        'employee_iin', temp_payment_records.employee_iin,
                        'account', temp_payment_records.target_account,
                        'amount', temp_payment_records.amount,
                        'error', 'критическая ошибка зачисления: ' || v_error_message
                    );

                    perform log_error_to_audit(
                        'transactions', 'failed_deposit', 'batch_err', v_error_message,
                        jsonb_build_object('batch_id', v_batch_id, 'payment', temp_payment_records)
                    );
            end;
        end loop;

        commit;

    exception
        when others then
            rollback;
            get stacked diagnostics v_error_code = returned_sqlstate, v_error_message = message_text;
            perform log_error_to_audit(
                'salary_batch', 'failed_batch', v_error_code, v_error_message,
                jsonb_build_object('company_account', p_company_account, 'total_amount', v_total_amount, 'payments_data', p_payments)
            );
            perform pg_advisory_unlock(hashtext(p_company_account));
            raise exception 'пакетная обработка прервана. ошибка: %', v_error_message;
    end;

    perform pg_advisory_unlock(hashtext(p_company_account));

    drop materialized view if exists salary_batch_report;

    create materialized view salary_batch_report as
    select
        current_timestamp as report_time,
        v_batch_id as batch_id,
        p_company_account as company_account,
        v_success_count as successful_payments,
        v_failed_count as failed_payments,
        v_total_successful_amount as total_amount_kzt,
        v_failed_details as failed_details,
        v_company_balance as company_new_balance
    with no data;

    refresh materialized view salary_batch_report;

    raise notice 'пакетная обработка завершена: успешно - %, неудачно - %, общая сумма - % kzt. новый баланс компании: %',
                 v_success_count, v_failed_count, v_total_successful_amount, v_company_balance;

end;
$$;

--task2: views
create or replace view customer_balance_summary as
with customer_balances as (
    select
        c.customer_id, c.full_name, c.tin, c.status, c.daily_limit_kzt,
        a.account_id, a.account_number, a.currency, a.balance,
        coalesce(er.rate, 1) as rate_to_kzt,
        a.balance * coalesce(er.rate, 1) as balance_kzt
    from customers c
    join accounts a on a.customer_id = c.customer_id and a.is_active = true
    left join exchange_rates er on
        er.from_currency = a.currency
        and er.to_currency = 'kzt'
        and current_timestamp between er.valid_from and er.valid_to
),
today_transfers as (
    select
        a.customer_id,
        sum(t.amount_kzt) as used_limit_kzt
    from transactions t
    join accounts a on a.account_id = t.from_account_id
    where t.status = 'completed'
      and t.type = 'transfer'
      and date(t.created_at) = current_date
    group by a.customer_id
)
select
    cb.customer_id,
    cb.full_name,
    cb.tin,
    cb.status,
    cb.daily_limit_kzt,
    cb.account_number,
    cb.currency,
    cb.balance,
    cb.balance_kzt,
    sum(cb.balance_kzt) over (partition by cb.customer_id) as total_balance_kzt,
    coalesce(tt.used_limit_kzt, 0) as used_limit_today_kzt,
    cb.daily_limit_kzt - coalesce(tt.used_limit_kzt, 0) as remaining_limit_kzt,
    case
        when cb.daily_limit_kzt > 0 then
            round((coalesce(tt.used_limit_kzt, 0) / cb.daily_limit_kzt) * 100, 2)
        else 0
    end as limit_utilization_percent,
    rank() over (order by sum(cb.balance_kzt) over (partition by cb.customer_id) desc) as balance_rank
from customer_balances cb
left join today_transfers tt on tt.customer_id = cb.customer_id;

create or replace view daily_transaction_report as
with daily_stats as (
    select
        date(created_at) as tx_date,
        type,
        count(*) as transaction_count,
        sum(amount_kzt) as total_amount_kzt,
        avg(amount_kzt) as avg_amount_kzt
    from transactions
    where status = 'completed'
    group by date(created_at), type
)
select
    tx_date,
    type,
    transaction_count,
    total_amount_kzt,
    avg_amount_kzt,
    sum(total_amount_kzt) over (partition by type order by tx_date) as running_total_type,
    sum(total_amount_kzt) over (order by tx_date) as running_total_all,
    lag(total_amount_kzt) over (partition by type order by tx_date) as prev_day_amount,
    case
        when lag(total_amount_kzt) over (partition by type order by tx_date) > 0 then
            round(((total_amount_kzt - lag(total_amount_kzt) over (partition by type order by tx_date)) /
                    lag(total_amount_kzt) over (partition by type order by tx_date)) * 100, 2)
        else null
    end as day_over_day_growth_percent
from daily_stats
order by tx_date desc, type;

create or replace view suspicious_activity_view
with (security_barrier = true)
as
with large_transactions as (
    select
        t.*,
        'large_transaction' as reason
    from transactions t
    where t.amount_kzt > 5000000
      and t.status = 'completed'
),
frequent_transactions as (
    select
        t.*,
        'high_frequency' as reason
    from transactions t
    join accounts a on a.account_id = t.from_account_id
    where t.status = 'completed'
      and t.created_at >= now() - interval '1 hour'
      and (count(*) over (partition by a.customer_id, date_trunc('hour', t.created_at)) > 10)
),
rapid_transfers as (
    select
        t2.*,
        'rapid_sequential' as reason
    from transactions t1
    join transactions t2 on
        t1.from_account_id = t2.from_account_id
        and t2.transaction_id > t1.transaction_id
        and t2.created_at - t1.created_at < interval '1 minute'
        and t1.status = 'completed'
        and t2.status = 'completed'
)
select distinct * from large_transactions
union all
select distinct * from frequent_transactions
union all
select distinct * from rapid_transfers;


--task3: indexes
create index idx_transactions_created_at_btree on transactions(created_at);
create index idx_accounts_number_hash on accounts using hash(account_number);
create index idx_accounts_active_partial on accounts(account_id, customer_id, balance) where is_active = true;
create index idx_customers_email_lower on customers(lower(email));
create index idx_audit_log_jsonb_gin on audit_log using gin(new_values);
create index idx_transactions_from_date_status on transactions(from_account_id, created_at, status, amount_kzt);


-- dml: тестовые данные
/*
insert into customers (tin, full_name, status, daily_limit_kzt) values
('900101123456', 'тоо "компания альфа"', 'active', 100000000),
('950303654321', 'Айбатова Сабина', 'active', 1000000),
('970707111222', 'Есеналиев Бек', 'active', 500000),
('960606333444', 'Оразхан Санжар', 'active', 500000),
('980808555666', 'заблокированный клиент', 'blocked', 500000);

insert into accounts (customer_id, account_number, currency, balance) values
(1, 'kz001000000000000001', 'kzt', 100000000),
(2, 'kz002000000000000001', 'kzt', 500000),
(3, 'kz003000000000000001', 'kzt', 150000),
(4, 'kz004000000000000001', 'kzt', 100000),
(2, 'kz002000000000000002', 'usd', 10000),
(3, 'kz003000000000000002', 'eur', 5000),
(5, 'kz005000000000000001', 'kzt', 10000);

insert into exchange_rates (from_currency, to_currency, rate, valid_from, valid_to) values
('usd', 'kzt', 450.0000, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('eur', 'kzt', 480.0000, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('rub', 'kzt', 4.5000, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('usd', 'eur', 0.9375, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('eur', 'usd', 1.0667, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('kzt', 'usd', 0.002222, current_timestamp - interval '1 hour', current_timestamp + interval '1 year'),
('kzt', 'eur', 0.002083, current_timestamp - interval '1 hour', current_timestamp + interval '1 year');

insert into transactions (from_account_id, to_account_id, amount, currency, exchange_rate, amount_kzt, to_amount, to_currency, type, status, created_at, completed_at, description) values
(2, 3, 50000, 'kzt', 1, 50000, 50000, 'kzt', 'transfer', 'completed', current_date, current_timestamp, 'транзакция для лимита');
*/

--test_scenarios
/*
\echo '--- тесты начало. проверка стартовых балансов: ---'
select full_name, account_number, currency, balance from customer_balance_summary where customer_id in (2, 3, 4, 1) and currency in ('kzt', 'usd', 'eur');

\echo '--- тест 1: перевод kzt -> kzt (стандартный перевод) ---'
call process_transfer(
    'kz002000000000000001',
    'kz003000000000000001',
    100000,
    'kzt',
    'тестовый перевод kzt->kzt'
);
select full_name, account_number, balance from customer_balance_summary where customer_id in (2, 3) and currency = 'kzt';


\echo '--- тест 2: перевод usd -> kzt (мультивалютный перевод) ---'
call process_transfer(
    'kz002000000000000002',
    'kz003000000000000001',
    100,
    'usd',
    'тестовый перевод usd->kzt'
);
select full_name, account_number, currency, balance from customer_balance_summary where customer_id in (2, 3) and currency in ('usd', 'kzt');


\echo '--- тест 3: перевод usd -> eur (мультивалютный перевод) ---'
call process_transfer(
    'kz002000000000000002',
    'kz003000000000000002',
    50,
    'usd',
    'тестовый перевод usd->eur'
);
select full_name, account_number, currency, balance from customer_balance_summary where customer_id in (2, 3) and currency in ('usd', 'eur');


\echo '--- тест 4: пакетная обработка зарплаты ---'
call process_salary_batch(
    'kz001000000000000001',
    '[{"account": "kz002000000000000001", "amount": 500000, "iin": "950303654321", "description": "январь"},
      {"account": "kz003000000000000001", "amount": 300000, "iin": "970707111222", "description": "январь"},
      {"account": "kz004000000000000001", "amount": 400000, "iin": "960606333444", "description": "январь"}]'::jsonb,
    'зарплата за январь 2024'
);
select full_name, account_number, balance from customer_balance_summary where customer_id in (1, 2, 3, 4) and currency = 'kzt';

\echo '--- тест 5: проверка отчета по пакетной обработке (materialized view) ---'
select successful_payments, failed_payments, total_amount_kzt, company_new_balance, failed_details from salary_batch_report;

\echo '--- тест 6: неудачный перевод (превышение лимита - tr007) ---'
begin;
select 'попытка перевода 800000 kzt (должно вызвать ошибку tr007 - лимит превышен)' as status;
do $$
begin
    call process_transfer(
        'kz002000000000000001',
        'kz003000000000000001',
        800000,
        'kzt',
        'попытка превысить лимит'
    );
exception
    when others then
        raise notice 'ожидаемая ошибка: % - %', sqlstate, sqlerrm;
end
$$;
rollback;

\echo 'проверка аудита ошибки:'
select action, (new_values->>'error_message') as error_message from audit_log where action = 'failed' order by log_id desc limit 1;
*/ 




-- --------------------------------------------------------------
--  объяснение и анализ индексов

-- -----------------------------------------------------------
-- ii. explain analyze outputs 

-- 1. индекс: idx_transactions_from_date_status (покрывающий индекс для лимита)

/*
тестовый запрос (проверка дневного лимита):
explain analyze
select coalesce(sum(amount_kzt), 0)
from transactions
where from_account_id = 2 and status = 'completed' and date(created_at) = current_date and type = 'transfer';
*/

-- ожидаемый вывод:
/*
aggregate  (...) 
  ->  index only scan using idx_transactions_from_date_status on transactions  (...)
        index cond: (from_account_id = 2) and (created_at >= '2025-12-12 00:00:00')
        ...
        heap fetches: 0
*/
--объяснение:это наш самый важный индекс для высоконагруженных проверок лимитов. строка **'index only scan' и 'heap fetches: 0' означает, что базе данных не нужно обращаться к основной таблице за данными. она берет всю информацию (сумму `amount_kzt`) прямо из индекса.благодаря этому проверка дневного лимита происходит мгновенно

-- 2. индекс: idx_accounts_number_hash (hash-индекс для быстрого поиска счета)

/*
тестовый запрос (поиск счета отправителя/получателя):
explain analyze
select account_id, currency, customer_id
from accounts
where account_number = 'kz002000000000000001';
*/

-- ожидаемый вывод:
/*
index scan using idx_accounts_number_hash on accounts  (...)
  index cond: (account_number = 'kz002000000000000001'::text)
*/
--бъяснение:хеш-индексы чемпионы по поиску точных совпадений.строка 'index scan using idx_accounts_number_hash'гарантирует, что поиск счета отправителя или получателя занимает минимум времени, даже если в системе будут миллионы счетов

-- 3. индекс: idx_audit_log_jsonb_gin (gin-индекс для jsonb)

/*
тестовый запрос (поиск ошибок в логах):
explain analyze
select *
from audit_log
where new_values @> '{"error_code": "tr007"}';
*/

--ожидаемый вывод:
/*
bitmap heap scan on audit_log  (...)
  recheck cond: (new_values @> '{"error_code": "tr007"}'::jsonb)
  ->  bitmap index scan on idx_audit_log_jsonb_gin  (...)
*/
--объяснение:этот индекс необходим для быстрого поиска внутри неструктурированного jsonb-поля. когда мы ищем конкретный код ошибки (например, 'tr007'),gin-индекс позволяет ссубд найти это, не сканируя все записи аудита, что критически важно для оперативного анализа ошибок

-- 4. индекс: idx_accounts_active_partial (частичный индекс)

/*
тестовый запрос (поиск активных счетов):
explain analyze
select account_id, balance
from accounts
where customer_id = 2 and is_active = true;
*/

-- ожидаемый вывод:
/*
index scan using idx_accounts_active_partial on accounts  (...)
  index cond: (customer_id = 2)
  filter: is_active
*/
бъяснение:это частичный индекс,который был создан только для активных счетов (`where is_active = true`)поскольку ссубд знает, что в индексе нет неактивных счетов,поиск происходит быстрее,а сам индекс занимает меньше места на диске.

-- 5. индекс: idx_customers_email_lower (индекс по выражению)

/*
тестовый запрос (поиск клиента по email без учета регистра):
explain analyze
select *
from customers
where lower(email) = 'sabina.aib@test.kz';
*/

-- ожидаемый вывод:
/*
index scan using idx_customers_email_lower on customers  (...)
  index cond: (lower(email) = 'sabina.aib@test.kz'::text)
*/
--объяснение:это позволяет менеджеру искать клиента по email без учета регистр строка 'index scan using idx_customers_email_lower'показывает, что индекс обрабатывает команду `lower()`, что делает поиск мгновенным, в отличие от медленного сканирования всей таблицы

-- 6. индекс: idx_transactions_created_at_btree (b-tree для отчетов)

/*
тестовый запрос (поиск транзакций за последние 24 часа):
explain analyze
select transaction_id, amount_kzt
from transactions
where created_at > now() - interval '24 hours'
order by created_at desc;
*/

-- ожидаемый вывод:
/*
index scan backward using idx_transactions_created_at_btree on transactions  (...)
  index cond: (created_at > (now() - '24:00:00'::interval))
*/
--объяснение: это стандартный b-tree индекс, который мы используем для построения отчетов. строка 'index scan backward' показывает, что ссубд сканирует индекс с конца, что идеально, если нам нужны самые свежие транзакции (например, за последние 24 часа)