# The retrieval index's database: PostgreSQL with pgvector, one database,
# owned by the user who runs llmq-index on this machine.
#
# One of open-slop's NixOS modules. Inert until services.open-slop.rag.enable.
#
# ============================================================================
# WHAT THIS MODULE DOES AND DOES NOT DO
# ============================================================================
#
# It enables services.postgresql (a host that already runs it, such as
# blade for Forgejo, keeps its one server), adds pgvector to it, creates the
# database and the owning role, and creates the vector extension as the
# superuser, because pgvector is not a trusted extension and the owner
# cannot create it.
#
# It does not open a port. The owner reaches the database over the local
# socket with peer authentication, which is NixOS's default, so llmq-index
# runs on this machine. The files it indexes can be anywhere this machine
# can read, NAS mounts included.
#
# It does not persist anything. The data directory is
# config.services.postgresql.dataDir, and a consumer with impermanence must
# already persist it if Postgres runs there for anything else; blade does,
# for Forgejo. A host that gets Postgres only from this module must add that
# directory to its own persistence.
#
# It does not schedule ingestion. Embedding a corpus on oracle's CPU is the
# same kind of long, contended job as a benchmark run, and it is started by
# hand: llmq-index ingest DIR.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop.rag;
  pg = config.services.postgresql;
  inherit (lib) types;
in
{
  options.services.open-slop.rag = {
    enable = lib.mkEnableOption "the PostgreSQL database behind llmq-index";

    database = lib.mkOption {
      type = types.strMatching "[a-z_][a-z0-9_]*";
      default = "llmq_rag";
      description = "Database name. llmq-index connects to dbname=llmq_rag unless told otherwise.";
    };

    owner = lib.mkOption {
      type = types.strMatching "[a-z_][a-z0-9_-]*";
      example = "bismuth";
      description = ''
        The login user who runs llmq-index here. A role of the same name is
        created and given the database, so peer authentication over the
        local socket lets that user, and no other, read and write the index.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.users.users ? ${cfg.owner};
        message = "services.open-slop.rag.owner is ${cfg.owner}, which is not a user on this machine.";
      }
    ];

    services.postgresql = {
      enable = true;
      extensions = ps: [ ps.pgvector ];
      ensureDatabases = [ cfg.database ];
      ensureUsers = [ { name = cfg.owner; } ];
    };

    # After postgresql-setup where that unit exists (nixpkgs since 25.05
    # runs ensureDatabases and ensureUsers there) and after postgresql
    # itself where it does not. An After= on a unit that does not exist is
    # ignored.
    systemd.services.open-slop-rag-db = {
      description = "Create the vector extension and hand the llmq-index database to its owner";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql.service" ];
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      path = [ pg.package ];
      script = ''
        set -euo pipefail
        for _ in $(seq 1 30); do
          if psql -d ${cfg.database} -tAc 'SELECT 1' >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done
        psql -v ON_ERROR_STOP=1 -d ${cfg.database} <<'SQL'
        CREATE EXTENSION IF NOT EXISTS vector;
        ALTER DATABASE "${cfg.database}" OWNER TO "${cfg.owner}";
        ALTER SCHEMA public OWNER TO "${cfg.owner}";
        SQL
      '';
    };
  };
}
