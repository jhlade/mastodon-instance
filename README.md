
## mastodon-instance
Dockerized Mastodon instance - multiple instances behind master front proxy
(and/or behind cascading proxies). Optimized for Joutsen Bulwark environment.

**Usage:**

- Create a new instance
`./prepare.sh <domain.tld> <admin_username> <admin-email>`

- Remove everything
`./wipe.sh`

- Start instance
`./run.sh`

- Stop instance
`./stop.sh`

- Update to specific tag
`./update.sh <new mastodon version, ie. v4.2.8>`


