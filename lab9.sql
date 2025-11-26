create or replace function calculate_discount(original_price numeric, discount_percent numeric)
returns numeric as $$
begin
    return original_price - (original_price * discount_percent / 100);
end;
$$ language plpgsql;

create or replace function film_stats(p_rating varchar, out total_films integer, out avg_rental_rate numeric)
as $$
begin
    select count(*), avg(rental_rate)
    into total_films, avg_rental_rate
    from film
    where rating = p_rating;
end;
$$ language plpgsql;

create or replace function get_customer_rentals(p_customer_id integer)
returns table(rental_date date, film_title varchar, return_date date) as $$
begin
    return query
    select r.rental_date, f.title, r.return_date
    from rental r
    join inventory i on r.inventory_id = i.inventory_id
    join film f on i.film_id = f.film_id
    where r.customer_id = p_customer_id;
end;
$$ language plpgsql;

create or replace function search_films(p_title_pattern varchar)
returns table(title varchar, release_year integer) as $$
begin
    return query
    select f.title, f.release_year
    from film f
    where f.title ilike p_title_pattern;
end;
$$ language plpgsql;

create or replace function search_films(p_title_pattern varchar, p_rating varchar)
returns table(title varchar, release_year integer, rating varchar) as $$
begin
    return query
    select f.title, f.release_year, f.rating
    from film f
    where f.title ilike p_title_pattern and f.rating = p_rating;
end;
$$ language plpgsql;