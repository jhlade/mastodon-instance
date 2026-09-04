#!/usr/bin/bash

set -Eeuo pipefail

_DATA="./data"
_BACKUP_DIR="${BACKUP_DIR:-./backup}"
_PROJECT_ENV="./.env"

declare -a _DC
declare -a _COMPOSE_FILES

mi_env_value() {
	local key="$1"
	local value=""

	if [ -f "${_PROJECT_ENV}" ]; then
		value=$(sed -n "s/^${key}=//p" "${_PROJECT_ENV}" | tail -n 1)
		value="${value#\"}"
		value="${value%\"}"
	fi

	printf '%s' "${value}"
}

mi_set_env_value() {
	local key="$1"
	local value="$2"
	local temporary_file

	touch "${_PROJECT_ENV}"
	temporary_file=$(mktemp "${_PROJECT_ENV}.XXXXXX")
	awk -v key="${key}" -v value="${value}" '
		BEGIN { found = 0 }
		index($0, key "=") == 1 {
			if (!found) {
				print key "=" value
				found = 1
			}
			next
		}
		{ print }
		END {
			if (!found) print key "=" value
		}
	' "${_PROJECT_ENV}" > "${temporary_file}"
	mv "${temporary_file}" "${_PROJECT_ENV}"
}

mi_configure_search_backend() {
	local backend="${1:-elasticsearch}"
	local backend_file="./docker-compose.${backend}.yml"

	case "${backend}" in
		elasticsearch|opensearch)
			;;
		*)
			echo "[ ! ] Unsupported search backend: ${backend}" >&2
			echo "      Use elasticsearch or opensearch." >&2
			exit 1
			;;
	esac

	if [ ! -f "${backend_file}" ]; then
		echo "[ ! ] Missing Compose configuration: ${backend_file}" >&2
		exit 1
	fi

	_SEARCH_BACKEND="${backend}"
	_COMPOSE_FILES=(-f ./docker-compose.yml -f "${backend_file}")
}

mi_detect_compose() {
	if [ -n "${COMPOSE_CMD:-}" ]; then
		read -r -a _DC <<< "${COMPOSE_CMD}"

		if ! command -v "${_DC[0]}" >/dev/null 2>&1; then
			echo "[ ! ] Compose command not found: ${_DC[0]}" >&2
			exit 1
		fi

		return
	fi

	# Prefer Podman when present
	if command -v podman >/dev/null 2>&1; then
		_DC=(podman compose)
	elif command -v docker >/dev/null 2>&1; then
		_DC=(docker compose)
	elif command -v docker-compose >/dev/null 2>&1; then
		_DC=(docker-compose)
	elif command -v podman-compose >/dev/null 2>&1; then
		_DC=(podman-compose)
	else
		echo "[ ! ] No Compose implementation found." >&2
		echo "      Install Podman or Docker, or set COMPOSE_CMD explicitly." >&2
		exit 1
	fi
}

dc() {
	"${_DC[@]}" "${_COMPOSE_FILES[@]}" "$@"
}

mi_detect_compose
mi_configure_search_backend "${SEARCH_BACKEND:-$(mi_env_value SEARCH_BACKEND)}"

# START INSTANCE
mi_start() {
	dc up -d
	sleep 10
	dc up -d nginx-proxy
}

# STOP INSTANCE
mi_stop() {
	dc down
}

# RESTART INSTANCE
mi_restart() {
	dc down
	sleep 5
	dc up -d
	sleep 10
	dc up -d nginx-proxy
}

# WIPE INSTANCE
mi_wipe() {
	dc down
	rm -rf -- "${_DATA}"
	mkdir -p "${_DATA}" ./env
	touch "${_DATA}/.placeholder"
	: > ./env/app.env
	: > ./env/db.env
	: > ./env/smtp.env
	chmod 0600 ./env/app.env ./env/db.env ./env/smtp.env
	echo "[ i ] Instance data and generated configuration removed."
}

# BACKUP DATABASE
mi_backup_pg() {
	local backup_file="${_BACKUP_DIR}/$(date +%F).dump"
	local temporary_file

	mkdir -p "${_BACKUP_DIR}"
	chmod 0700 "${_BACKUP_DIR}"

	if [ -e "${backup_file}" ]; then
		echo "[ ! ] Backup already exists: ${backup_file}" >&2
		return 1
	fi

	temporary_file=$(mktemp "${_BACKUP_DIR}/.mastodon-backup.XXXXXX")
	echo "[ i ] Backing up PostgreSQL to ${backup_file}..."
	if dc exec -T postgresql sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > "${temporary_file}"; then
		mv "${temporary_file}" "${backup_file}"
		echo "[ i ] Backup complete: ${backup_file}"
	else
		rm -f "${temporary_file}"
		return 1
	fi
}

# SWITCH SEARCH BACKEND
mi_search_backend() {
	local backend="$1"

	case "${backend}" in
		elasticsearch|opensearch)
			;;
		*)
			echo "[ ! ] Unsupported search backend: ${backend}" >&2
			echo "      Use elasticsearch or opensearch." >&2
			exit 1
			;;
	esac

	if [ "${backend}" = "${_SEARCH_BACKEND}" ]; then
		echo "[ i ] Search backend is already ${backend}."
		return
	fi

	echo "[ i ] Switching search backend from ${_SEARCH_BACKEND} to ${backend}..."
	dc stop elasticsearch
	mi_set_env_value SEARCH_BACKEND "\"${backend}\""
	mi_configure_search_backend "${backend}"
	mkdir -p "${_DATA}/${backend}"
	dc up -d elasticsearch
	echo "[ i ] Waiting for ${backend}..."
	sleep 20
	dc run --rm control bin/tootctl search deploy
	echo "[ i ] Search backend switched to ${backend}."
}

# UPDATE MASTODON
mi_update() {
	mi_set_env_value MASTODON_VER "\"$1\""

	echo "[ i ] Pulling Mastodon $1..."
	dc pull web streaming sidekiq control
	dc up -d postgresql redis redis-cache elasticsearch
	sleep 10
	dc run --rm -u root control bash -c "find /mastodon/public/ -mindepth 1 -maxdepth 1 ! -name system -exec cp -r {} /web/ \\;"
	echo "[ i ] Running pre-deployment database migrations..."
	dc run --rm -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true control bundle exec rails db:migrate
	echo "[ i ] Restarting Mastodon services..."
	dc up -d
	echo "[ i ] Running post-deployment database migrations..."
	dc run --rm control bundle exec rails db:migrate
	echo "[ i ] Deploying the search index..."
	dc run --rm control bin/tootctl search deploy
	echo "[ i ] Update complete."
}

# PREPARE INSTANCE
mi_prepare() {

	# structure
	mkdir -p ${_DATA}/{web,postgresql,redis}
	mkdir -p "${_DATA}/${_SEARCH_BACKEND}"
	mkdir -p ${_DATA}/web/{assets,system}
	chown -R 991:991 ${_DATA}/web

	DOMAIN="$1"
	MASTODON_ADMIN_USERNAME="$2"
	MASTODON_ADMIN_EMAIL="$3"

	dc down

	echo "[ i ] Preparing instance ${DOMAIN}..."

	# Create db.env
	touch ./env/db.env
	echo "" > ./env/db.env

	__PG_HOST="postgresql"
	__PG_USER="mastodon"
	__PG_DB="mastodon_production"

	# PostgreSQL
	echo "POSTGRES_USER=$__PG_USER" >> ./env/db.env
	echo "POSTGRES_DB=$__PG_DB" >> ./env/db.env
	# Mastodon DB access
	echo "DB_HOST=$__PG_HOST" >> ./env/db.env
	echo "DB_USER=$__PG_USER" >> ./env/db.env
	echo "DB_NAME=$__PG_DB" >> ./env/db.env
	echo "DB_PORT=5432" >> ./env/db.env
	# Valkey
	echo "REDIS_HOST=redis" >> ./env/db.env
	echo "REDIS_PORT=6379" >> ./env/db.env
	echo "CACHE_REDIS_HOST=redis-cache" >> ./env/db.env
	echo "CACHE_REDIS_PORT=6379" >> ./env/db.env
	# Elasticsearch-compatible search backend
	echo "ES_ENABLED=true" >> ./env/db.env
	echo "ES_HOST=elasticsearch" >> ./env/db.env
	echo "ES_PORT=9200" >> ./env/db.env

	# generate passwords
	__PWD_PG=$( openssl rand -hex 16 )

	echo "POSTGRES_PASSWORD=${__PWD_PG}" >> ./env/db.env
	echo "DB_PASS=${__PWD_PG}" >> ./env/db.env

	[ ! -s ./env/db.env ] && { echo "[ ! ] Failed to create database environment file."; exit 1; }
	echo "[ i ] Database environment file created."

	# secure the file
	chmod 0600 ./env/db.env

	# Create app.env
	touch ./env/app.env
	echo "" > ./env/app.env

	echo "S3_ENABLED=false" >> ./env/app.env
	echo "RAILS_ENV=production" >> ./env/app.env
	echo "NODE_ENV=production" >> ./env/app.env
	echo "LOCAL_DOMAIN=${1}" >> ./env/app.env
	echo "SINGLE_USER_MODE=false" >> ./env/app.env

	# do not serve static files via rails
	echo "RAILS_SERVE_STATIC_FILES=false" >> ./env/app.env
	# instance locale - CZ
	echo "DEFAULT_LOCALE=cs" >> ./env/app.env

	__S_KEY=$( openssl rand -hex 64 )
	__S_OTP=$( openssl rand -hex 64 )

	rm -rf ./tmp
	mkdir -p ./tmp/
	openssl ecparam -name prime256v1 -genkey -noout -out ./tmp/vapid_private_key.pem > /dev/null 2>&1
	openssl ec -in ./tmp/vapid_private_key.pem -pubout -out ./tmp/vapid_public_key.pem > /dev/null 2>&1

	__S_VAP_PUB=$( cat -e ./tmp/vapid_public_key.pem | sed -e "1 d" -e "$ d" | tr -d "\n" )
	__S_VAP_PRI=$( cat -e ./tmp/vapid_private_key.pem | sed -e "1 d" -e "$ d" | tr -d "\n" )

	rm -rf ./tmp

	# Set the application secrets
	echo "SECRET_KEY_BASE=${__S_KEY}" >> ./env/app.env
	echo "OTP_SECRET=${__S_OTP}" >> ./env/app.env
	echo "VAPID_PRIVATE_KEY=${__S_VAP_PRI}" >> ./env/app.env
	echo "VAPID_PUBLIC_KEY=${__S_VAP_PUB}" >> ./env/app.env
	
	# active record secrets
	# TODO - generate actual keys
	echo "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=" >> ./env/app.env
	echo "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=" >> ./env/app.env
	echo "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=" >> ./env/app.env
	
	# Trusted proxy in Docker
	echo "TRUSTED_PROXY_IP=127.0.0.1/32,172.16.0.0/12,10.89.0.0/15" >> ./env/app.env

	[ ! -s ./env/app.env ] && { echo "[ ! ] Failed to create application environment file."; exit 1; }
	echo "[ i ] Application environment file created."

	# Secure the file
	chmod 0600 ./env/app.env

	# Copy static files
	echo "[ i ] Copying static files..."
	dc run --rm -u root control bash -c "find /mastodon/public/ -mindepth 1 -maxdepth 1 ! -name system -exec cp -r {} /web/ \\;"

	# Prepare PostgreSQL database
	dc up -d postgresql redis redis-cache elasticsearch
	echo "[ i ] Waiting for database..."
	sleep 20

	CHECK=${_DATA}/.provisioned

	if [ -f "$CHECK" ]; then
		echo "Provisioning not required"
	else

		dc run --rm control bundle exec rake db:migrate

		dc run --rm control bin/tootctl search deploy
		dc run --rm control bin/tootctl accounts create $MASTODON_ADMIN_USERNAME --email $MASTODON_ADMIN_EMAIL --confirmed --role Owner

		echo "[ i ] Provisioning done. Check env/app.env for additional configuration."
		touch "$CHECK"
	fi

	dc up -d
}

# CONTROL
case "${1:-}" in
  start)
    	mi_start
    ;;
  stop)
		mi_stop
	;;
  restart)
		mi_restart
    ;;
  wipe)
		mi_wipe
	;;
  update)
  		[ $# -ne 2 ] && { echo "Usage: $0 update <mastodon version>"; exit 1; }
  		mi_update "$2"
  	;;
  backup)
  		mi_backup_pg
    ;;
  search)
		[ $# -ne 2 ] && { echo "Usage: $0 search <elasticsearch|opensearch>"; exit 1; }
		mi_search_backend "$2"
    ;;
  compose)
		shift
		[ $# -eq 0 ] && { echo "Usage: $0 compose <arguments...>"; exit 1; }
		dc "$@"
    ;;
  init)
        [ $# -ne 4 ] && { echo "Usage: $0 init <my-domain.tld> <admin_username> <admin-email@domain.tld>"; exit 1; }
  		mi_prepare "$2" "$3" "$4"
    ;;  
  prepare)
  		[ $# -ne 4 ] && { echo "Usage: $0 prepare <my-domain.tld> <admin_username> <admin-email@domain.tld>"; exit 1; }
  		mi_prepare "$2" "$3" "$4"
  	;;
  *)
  echo "Usage: $0 {start|stop|restart|wipe|update <mastodon version>|search <elasticsearch|opensearch>|compose <arguments...>|init|backup}"
  exit 1
  ;;
esac

exit 0
