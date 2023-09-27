CREATE ROLE {role} WITH
  LOGIN
  SUPERUSER
  INHERIT
  CREATEDB
  CREATEROLE
  REPLICATION;

COMMENT ON ROLE {role} IS '{description}';

ALTER ROLE {role} with encrypted password '{pw}';
