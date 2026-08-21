
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

- Update to specific tag
`./control.sh update <new mastodon version, ie. v4.3.6>`

**Update to 4.3.0 from 4.2.x:**
Run
`docker-compose run --rm control bin/rails db:encryption:init`

and insert newly generated keys to your `.env/app.env` first.
