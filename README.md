
## mastodon-instance
Dockerized Mastodon instance - multiple instances behind master front proxy
(and/or behind cascading proxies). Optimized for Joutsen Bulwark environment
running Podman on Linux.

`control.sh` prefers `podman compose` when Podman is installed. The Compose
implementation can be overridden for any command, for example with
`COMPOSE_CMD="docker compose" ./control.sh start`,
`COMPOSE_CMD=docker-compose ./control.sh start`, or
`COMPOSE_CMD=podman-compose ./control.sh start`.

**Usage:**

- Create a new instance
`./control.sh init <domain.tld> <admin_username> <admin-email>`

- Remove everything
`./control.sh wipe`

- Start instance
`./control.sh start`

- Stop instance
`./control.sh stop`

- Back up PostgreSQL
`./control.sh backup`

Backups are written in PostgreSQL custom format to `backup/YYYY-MM-DD.dump`.
The command refuses to overwrite an existing backup. Set `BACKUP_DIR` to use
a different destination.

- Update to specific tag
`./control.sh update <new mastodon version, ie. v4.7.0>`

The update command runs pre-deployment migrations with
`SKIP_POST_DEPLOYMENT_MIGRATIONS=true`, restarts the application, runs the
post-deployment migrations, and deploys the search index.

- Switch between Elasticsearch and OpenSearch
`./control.sh search <elasticsearch|opensearch>`

The selected search backend is stored as `SEARCH_BACKEND` in `.env`. Both
backends keep their indexes in separate data directories, and the switch
command deploys a fresh index automatically. `SEARCH_IMAGE` can be used to
override the image chosen by either backend.

- Pass a command to the selected Compose implementation
`./control.sh compose <arguments...>`

**Update to 4.3.0 from 4.2.x:**
Run
`./control.sh compose run --rm control bin/rails db:encryption:init`

and insert newly generated keys to your `.env/app.env` first.
