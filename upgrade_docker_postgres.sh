#!/bin/bash

# TODO:
#  - add a job file so the migration can be resumed if it stops for whatever reason (i.e.: no space left)
#  - add an option to pass parameters that cannot be discovered (i.e.: user/pass)
#  - add an option to provide 2-steps upgrade, without erasing the original volume

set -e

if [ ! $# -eq 2 ]; then
    >&2 echo "Usage: ${0} your-old-postgres-container target_postgres_based_image:tag [alternative_temp_location]"
    >&2 echo "Example 1: ${0} nextcloud_db postgres:15"
    >&2 echo "Example 2: ${0} fancy_db postgis:15-3.3 /temporary"
    exit 1
fi

CONTAINER="${1}"
IMAGE_TARGET="${2}"
[ -n "${3}" ] && TEMP_FILES_OPTIONS="-p ${3}"

PG_ENV=$(mktemp ${TEMP_FILES_OPTIONS})
PG_DUMP=$(mktemp ${TEMP_FILES_OPTIONS})
TEMP_CONTAINER="${CONTAINER}-upgrade-to-${IMAGE_TARGET//[^[:alnum:]]/_}"

TEMP_DB=$(echo $RANDOM | md5sum | head -c 20)

function wait_for_success() {
  local timeout start_time end_time
  timeout=${TIMEOUT:-60}
  interval=${INTERVAL:-2}
  start_time=$(date +%s)
  end_time=$((start_time + timeout))
  while [ $(date +%s) -lt ${end_time} ]; do
    if ${@}; then
      return 0
    fi
    sleep ${interval}
  done
  >&2 echo "Timeout exceeded."
  docker logs ${TEMP_CONTAINER} 1>&2
  return 1
}

printf '\nEnsure target image exists: '
  docker manifest inspect ${IMAGE_TARGET} >/dev/null
  if [ $? -ne 0 ]; then { echo "Failed, aborting." ; exit 1; } fi
printf 'Done'

## EMERGENCY MARKER ##

printf '\nEnsure original container is running: '
  docker start ${CONTAINER} >/dev/null
printf 'Done'

printf '\nBacking-up current database content: '
  docker inspect "${CONTAINER}" --format='{{range .Config.Env}}{{println .}}{{end}}' | egrep '(POSTGRES_USER|POSTGRES_PASSWORD|PGDATA)' > ${PG_ENV}
  # source variables skipping single quotes and wrapping all variables in single quotes just for this script. When Docker will source the PGENV file the escaping might cause issues
  source <(echo ${PG_ENV} | sed -r "s/\x27/'\"'\"'/g" | sed -r 's/^(\w+)=(.+)/\1=\x27\2\x27/')

  if [ ! -n "${POSTGRES_USER}" ];     then echo "POSTGRES_USER is not available!"     ; exit 1; fi
  if [ ! -n "${POSTGRES_PASSWORD}" ]; then echo "POSTGRES_PASSWORD is not available!" ; exit 1; fi

  CONTAINER_USER=$( docker exec "${CONTAINER}" id -u)
  CONTAINER_GROUP=$(docker exec "${CONTAINER}" id -g)

  if [ ! -z "${CONTAINER_USER}"  ]; then CONTAINER_USER="--user   ${CONTAINER_USER}" ; fi
  if [ ! -z "${CONTAINER_GROUP}" ]; then CONTAINER_USER="${CONTAINER_USER}:${CONTAINER_GROUP}"; fi

  DOCKER_OPTIONS="${CONTAINER_USER}"

  PGDATA="${PGDATA:-/var/lib/postgresql/data}"

  PG_SOURCE_TYPE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Type}}{{end}}{{end}}' ${CONTAINER})
  case "${PG_SOURCE_TYPE}" in
    bind)
      PG_SOURCE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Source}}{{end}}{{end}}' ${CONTAINER})
    ;;

    volume)
      PG_SOURCE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Name}}{{end}}{{end}}' ${CONTAINER})
    ;;

    *)
      printf '\nUnsupported mount type'
      exit 1
    ;;
  esac
printf 'Done'

printf '\nWaiting for PostgreSQL to spin-up: '
  wait_for_success docker exec -ti ${CONTAINER} pg_isready -U ${POSTGRES_USER} >/dev/null
printf 'Done'

printf '\nCreating a backup: '
  docker exec -it "${CONTAINER}" pg_dumpall -U ${POSTGRES_USER} > ${PG_DUMP}
  sed -i "/CREATE ROLE ${POSTGRES_USER};/d" ${PG_DUMP} # we have already created this role during the DB init
printf 'Done'

printf '\nStopping the original container: '
  docker stop "${CONTAINER}" >/dev/null
printf 'Done'

# if anything goes wrong after creating the backup... replace the two variables PG_ENV and PG_DUMP around line 20, uncomment the rows below and delete anything above up to the EMERGENCY MARKER
# set +e
# docker stop ${TEMP_CONTAINER} ; docker rm ${TEMP_CONTAINER}
# set -e
# source ${PG_ENV}
# PGDATA="${PGDATA:-/var/lib/postgresql/data}"
# PG_SOURCE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Name}}{{end}}{{end}}' ${CONTAINER})

printf '\nRemoving data from volume/bind: '
  docker run --rm -t ${DOCKER_OPTIONS} -v ${PG_SOURCE}:/volume_data alpine sh -c "rm -Rf /volume_data/*" >/dev/null
printf 'Done'

printf '\nSpinning-up new container to import data: '
  docker run --name ${TEMP_CONTAINER} -v ${PG_DUMP}:/dump.sql -v ${PG_SOURCE}:${PGDATA} -e POSTGRES_DB="${TEMP_DB}" --env-file ${PG_ENV} ${DOCKER_OPTIONS} -d ${IMAGE_TARGET} >/dev/null
printf 'Done'

printf '\nWaiting for PostgreSQL to spin-up: '
  wait_for_success docker exec -ti ${TEMP_CONTAINER} pg_isready -U ${POSTGRES_USER} >/dev/null
  sleep 15 # this SEEMS unnecessary but images like postgis restart the DB multiple times, tricking the above check. Still, we should find a better approach
printf 'Done'

printf '\nImporting data: '
  docker exec -i ${TEMP_CONTAINER} psql -U ${POSTGRES_USER} -d ${TEMP_DB} -f /dump.sql >/dev/null
printf 'Done'

printf '\nDropping temporary database: '
  docker exec -i ${TEMP_CONTAINER} psql -U ${POSTGRES_USER} -c "DROP DATABASE \"${TEMP_DB}\";" >/dev/null
printf 'Done'

printf '\nStopping and removing temporary PostgreSQL container: '
  docker stop ${TEMP_CONTAINER} >/dev/null
  docker rm   ${TEMP_CONTAINER} >/dev/null
printf 'Done'

printf '\nChecking version: '
  docker run --rm -v ${PG_SOURCE}:/volume_data ${DOCKER_OPTIONS} alpine sh -c "cat /volume_data/PG_VERSION"

printf "\nPlease update your original container or docker compose to use ${IMAGE_TARGET} and run the following commands to delete the residuals: \n"
printf "  rm ${PG_DUMP} # <- this is the database backup \n"
printf "  rm ${PG_ENV} # <- these are the database env variables \n\n"
printf "\nIf you get any permission issue for your pre-existing PostgreSQL role, execute on of these commands before deleting the files above:\n"
printf "  source ${PG_ENV}; export "'POSTGRES_PASSWORD=${POSTGRES_PASSWORD'"//\\\'/\\\'\\\'}"" ; docker exec -i ${CONTAINER} psql -U "$'${POSTGRES_USER} -c "ALTER USER ${POSTGRES_USER} WITH PASSWORD \'${POSTGRES_PASSWORD}\';"'" ; unset POSTGRES_USER ; unset POSTGRES_PASSWORD # for MD5 auth \n\n"
printf "  source ${PG_ENV}; export "'POSTGRES_PASSWORD=${POSTGRES_PASSWORD'"//\\\'/\\\'\\\'}"" ; docker exec -i ${CONTAINER} psql -U "$'${POSTGRES_USER} -c "SET password_encryption  = \'scram-sha-256\'; ALTER USER ${POSTGRES_USER} WITH PASSWORD \'${POSTGRES_PASSWORD}\';"'" ; unset POSTGRES_USER ; unset POSTGRES_PASSWORD # for SCRAM auth \n\n"
printf "\nSometimes you also need to drop the PATH ENV variable from your container. For example, if you are switching from the alpine to debian version of the postgres image\n\n"
