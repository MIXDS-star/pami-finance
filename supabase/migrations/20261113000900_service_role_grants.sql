-- Pami Finance · 0900 · Explicit privileges for the server role.
-- Projects created with "automatically expose new tables" disabled give no
-- default privileges to API roles. The client roles already receive explicit,
-- minimal grants (0400). The service role (used only by trusted Edge Functions,
-- e.g. delete-account) gets them explicitly here too. It still never reaches
-- the app: its key exists only as a server secret.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
