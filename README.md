
## mastodon-instance
Dockerized Mastodon instance - multiple instances behind master front proxy
(and/or behind cascading proxies). Optimized for Joutsen Bulwark environment.

**Usage:**

- Create a new instance
`./control.sh prepare <domain.tld> <admin_username> <admin-email>`

- Remove everything
`./control.sh wipe`

- Start instance
`./control.sh start`

- Stop instance
`./control.sh stop`

- Update to specific tag
`./constrol.sh update <new mastodon version, ie. v4.2.12>`


