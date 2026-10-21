-- create_names: the names sql_query lists and sql_transaction claims.

create table names (
  name text primary key,
  claimed_at text not null
) strict;
