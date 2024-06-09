#!/bin/bash

# TODO:
#  - add a job file so the migration can be resumed if it stops for whatever reason (i.e.: no space left)

set -e

help()
{
    >&2 echo "Usage for upgrade: ${0} -u your-old-postgres-container target_postgres_based_image:tag [alternative_temp_location]"
    >&2 echo "Example 1: ${0} -u nextcloud_db postgres:15"
    >&2 echo "Example 2: ${0} -u fancy_db postgis:15-3.3 /temporary"
    >&2 echo "Example 3: ${0} -u fancy_db postgis:15-3.3 /temporary"
    >&2 echo ""
    >&2 echo "Usage for recovery: ${0} -r your-new-postgres-container target_postgres_based_image:tag pg_dump_altered_backup_location temporary_script_env_file temporary_script_db_env_file"
    >&2 echo "Example 4: ${0} -r immich_postgres tensorchord/pgvecto-rs:pg16-v0.2.1 /tmp/tmp.QF8u6RnXcy_no_main_role /tmp/tmp.IRJUGNjPC7 /tmp/tmp.U21SVOaPOJ"
    >&2 echo ""
    >&2 echo "You can pass or overwrite the autodiscovered PostgreSQL credentials or data dir values using ENV variables before invoking the script"
    exit 1
}

case "${1}" in
  # upgrade
  '-u')
    if ! (( $# >= 3 && $# <= 4)); then
      help
    else
      export CONTAINER="${2}"
      export IMAGE_TARGET="${3}"
      [ -n "${4}" ] && export TEMP_FILES_OPTIONS="-p ${4}"

      export PG_ENV=$(mktemp ${TEMP_FILES_OPTIONS})
      export SCRIPT_PG_ENV=$(mktemp ${TEMP_FILES_OPTIONS})
      export SCRIPT_ENV=$(mktemp ${TEMP_FILES_OPTIONS})
      export PG_DATA_BACKUP=$(mktemp -d ${TEMP_FILES_OPTIONS})
      export PG_DUMP=$(mktemp ${TEMP_FILES_OPTIONS})
      export PG_DUMP_ALTERED=${PG_DUMP}_no_main_role
      export TEMP_CONTAINER="${CONTAINER}-upgrade-to-${IMAGE_TARGET//[^[:alnum:]]/_}"
    fi
  ;;
  # recovery backup
  '-r')
    if ! (( $# >= 6 && $# <= 6)); then
      help
    else
      export CONTAINER="${2}"
      export IMAGE_TARGET="${3}"

      export SCRIPT_PG_ENV=${6}
      export SCRIPT_ENV=${5}
      export PG_DUMP_ALTERED=${4}
      export TEMP_CONTAINER="${CONTAINER}-restore-to-${IMAGE_TARGET//[^[:alnum:]]/_}"
    fi
  ;;

  *)
    help
  ;;
esac

export TEMP_DB=$(echo $RANDOM | md5sum | head -c 20)

echo
echo '----'
echo "Temporary DB ENV file: ${PG_ENV}"
echo "Temporary script DB ENV file: ${SCRIPT_PG_ENV}"
echo "Temporary upgrade script ENV file: ${SCRIPT_ENV}"
echo "Temporary pg_data backup: ${PG_DATA_BACKUP}"
echo "Temporary pg_dump backup: ${PG_DUMP}"
echo "Temporary pg_dump altered backup: ${PG_DUMP_ALTERED}"
echo "Temporary database name: ${TEMP_DB}"
echo "Temporary container: ${TEMP_CONTAINER}"
echo '----'
echo

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

function ensure_target_image_exists() {
  printf '\nEnsure target image exists: '
    docker manifest inspect ${IMAGE_TARGET} >/dev/null
    if [ $? -ne 0 ]; then { echo "Failed, aborting." ; exit 1; } fi
  printf 'Done'
}

function start_original_container() {
  printf '\nEnsure original container is running: '
    docker start ${CONTAINER} >/dev/null
  printf 'Done'
}

function extract_original_container_info() {
  printf '\nExtracting original container info: '
    docker inspect "${CONTAINER}" --format='{{range .Config.Env}}{{println .}}{{end}}' | egrep '(POSTGRES_USER|POSTGRES_PASSWORD|PGDATA)' > ${PG_ENV}
    # if variables were already defined in the environment, use them instead of the ones detected from the container
    declare -a pg_variables=("POSTGRES_USER" "POSTGRES_PASSWORD" "PGDATA")
    for pg_variable in "${pg_variables[@]}"
    do
      if [ -n "${!pg_variable}" ]; then
        sed -i '/^${pg_variable}/d' ${PG_ENV}
        echo "${pg_variable}=${!pg_variable}" >> ${PG_ENV}
      fi
    done

    # source variables skipping single quotes and wrapping all variables in single quotes just for this script. When Docker will source the PGENV file the escaping might cause issues
    cat ${PG_ENV} | sed -r "s/\x27/'\"'\"'/g" | sed -r 's/^(\w+)=(.+)/\1=\x27\2\x27/' > ${SCRIPT_PG_ENV}

    source ${SCRIPT_PG_ENV}

    # stop everything if at this point we still don't know the user and pass
    if [ ! -n "${POSTGRES_USER}" ];     then echo "POSTGRES_USER is not available!"     ; exit 1; fi
    if [ ! -n "${POSTGRES_PASSWORD}" ]; then echo "POSTGRES_PASSWORD is not available!" ; exit 1; fi
    export POSTGRES_USER=${POSTGRES_USER}
    export POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

    export CONTAINER_USER=$( docker exec "${CONTAINER}" id -u)
    export CONTAINER_GROUP=$(docker exec "${CONTAINER}" id -g)

    # unfortunately, user or user+group are not defined in the same way
    if [ ! -z "${CONTAINER_USER}"  ]; then
      CONTAINER_USER="--user ${CONTAINER_USER}"
    fi
    if [ ! -z "${CONTAINER_GROUP}" ]; then
      CONTAINER_USER="${CONTAINER_USER}:${CONTAINER_GROUP}"
    fi
    # if [ -n "${CONTAINER_USER}" ]; then echo "CONTAINER_USER='${CONTAINER_USER}'" >> ${SCRIPT_ENV}

    export DOCKER_OPTIONS="${CONTAINER_USER}"
    echo "DOCKER_OPTIONS='${DOCKER_OPTIONS}'" >> ${SCRIPT_ENV}

    export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
    echo "PGDATA='${PGDATA}'" >> ${SCRIPT_ENV}

    # unfortunately, binds and volumes are not defined in the same way
    PG_SOURCE_TYPE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Type}}{{end}}{{end}}' ${CONTAINER})
    case "${PG_SOURCE_TYPE}" in
      bind)
        export PG_SOURCE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Source}}{{end}}{{end}}' ${CONTAINER})
      ;;

      volume)
        export PG_SOURCE=$(docker inspect --format='{{range $mount := .Mounts}}{{if eq $mount.Destination "'${PGDATA}'"}}{{.Name}}{{end}}{{end}}' ${CONTAINER})
      ;;

      *)
        printf '\nUnsupported mount type'
        exit 1
      ;;
    esac
    echo "PG_SOURCE='${PG_SOURCE}'" >> ${SCRIPT_ENV}

  printf 'Done'
}

function wait_for_db() {
  container=${1}

  printf '\nWaiting for PostgreSQL to spin-up: '
    wait_for_success docker exec -ti ${container} pg_isready -U ${POSTGRES_USER} >/dev/null
    sleep 15 # this SEEMS unnecessary but some images like postgis restart the DB multiple times, tricking the above check. Still, we should find a better approach because there is no guarantee that 15 seconds are enough (and probably it's too much)
  printf 'Done'
}

function wait_for_container() {
  container=${1}

  [ "`docker inspect -f {{.State.Running}} ${container}`" == "true" ]
}

function create_backup() {
  printf '\nCreating a backup: '
    docker exec -it "${CONTAINER}" pg_dumpall --clean --if-exists -U ${POSTGRES_USER} > ${PG_DUMP}
    cp ${PG_DUMP} ${PG_DUMP_ALTERED}
    sed -i "/CREATE ROLE ${POSTGRES_USER};/d" ${PG_DUMP_ALTERED} # removing from the backup as we have already created this role during the DB init
  printf 'Done'
}

function stop_original_container() {
  printf '\nStopping the original container: '
    docker stop "${CONTAINER}" >/dev/null
  printf 'Done'
}

function temporarily_move_data() {
  printf '\nMoving data in the volume/bind to the temporary folder: '
    docker run --rm -t ${DOCKER_OPTIONS} -v ${PG_SOURCE}:/volume_data -v ${PG_DATA_BACKUP}:/volume_data_backup alpine sh -c "cp -a /volume_data/* /volume_data_backup/* ; rm -Rf /volume_data/*" >/dev/null
  printf 'Done'
}

function clean_up_volume_before_import() {
  printf '\nClean-up the volume/bind before initiating the process: '
    docker run --rm -t ${DOCKER_OPTIONS} -v ${PG_SOURCE}:/volume_data alpine sh -c "rm -rf /volume_data/*" >/dev/null
  printf 'Done'
}

function start_new_container() {
  printf '\nSpinning-up new container to import data: '
    docker run --name ${TEMP_CONTAINER} -v ${PG_DUMP_ALTERED}:/dump.sql -v ${PG_SOURCE}:${PGDATA} -e POSTGRES_DB="${TEMP_DB}" --env-file ${PG_ENV} ${DOCKER_OPTIONS} -d ${IMAGE_TARGET} >/dev/null
  printf 'Done'
}

function import_data() {
  printf '\nImporting data: '
    docker exec -i ${TEMP_CONTAINER} psql -U ${POSTGRES_USER} -d ${TEMP_DB} -f /dump.sql >/dev/null
  printf 'Done'
}

function drop_temporary_database() {
  printf '\nDropping temporary database: '
    docker exec -i ${TEMP_CONTAINER} psql -U ${POSTGRES_USER} -c "DROP DATABASE \"${TEMP_DB}\";" >/dev/null
  printf 'Done'
}

function stop_and_remove_temporary_container() {
  printf '\nStopping and removing temporary PostgreSQL container: '
    docker stop ${TEMP_CONTAINER} >/dev/null
    docker rm   ${TEMP_CONTAINER} >/dev/null
  printf 'Done'
}

function check_container_version() {
  printf '\nChecking version: '
    docker run --rm -v ${PG_SOURCE}:/volume_data ${DOCKER_OPTIONS} alpine sh -c "cat /volume_data/PG_VERSION"
}

function print_final_notes() {
  echo "---------------------------------------------------------"
  printf "\nPlease update your original container or docker compose to use ${IMAGE_TARGET} and run the following commands to delete the residuals (if you skip the next step): \n"
  printf "  rm -Rf ${PG_DATA_BACKUP} # <- this is the original database data raw copy \n"
  printf "  rm ${PG_DUMP} # <- this is the database backup \n"
  printf "  rm ${PG_DUMP_ALTERED} # <- this is the altered database backup used for the upgrade \n"
  printf "  rm ${PG_ENV} ${SCRIPT_PG_ENV} ${SCRIPT_PG_ENV} ${PG_ENV} # <- these are the env variables used for the script \n"
  echo "---------------------------------------------------------"
  printf "\nIf you get any permission issue for your pre-existing PostgreSQL role, execute on of these commands before deleting the files above:\n"
  printf "  source ${SCRIPT_PG_ENV}; export "'POSTGRES_PASSWORD=${POSTGRES_PASSWORD'"//\\\'/\\\'\\\'}"" ; docker exec -i ${CONTAINER} psql -U "$'${POSTGRES_USER} -c "ALTER USER ${POSTGRES_USER} WITH PASSWORD \'${POSTGRES_PASSWORD}\';"'" ; unset POSTGRES_USER ; unset POSTGRES_PASSWORD # for MD5 auth \n\n"
  printf "  source ${SCRIPT_PG_ENV}; export "'POSTGRES_PASSWORD=${POSTGRES_PASSWORD'"//\\\'/\\\'\\\'}"" ; docker exec -i ${CONTAINER} psql -U "$'${POSTGRES_USER} -c "SET password_encryption  = \'scram-sha-256\'; ALTER USER ${POSTGRES_USER} WITH PASSWORD \'${POSTGRES_PASSWORD}\';"'" ; unset POSTGRES_USER ; unset POSTGRES_PASSWORD # for SCRAM auth \n"
  echo "---------------------------------------------------------"
  printf "\nSometimes you also need to drop the PATH ENV variable from your container. For example, if you are switching from the alpine to debian version of the postgres image\n"
  echo "---------------------------------------------------------"
}

function clean_up() {
  read -p "Would you like to remove the old data from the volume? " -n 1 -r

  echo
  if [[ ${REPLY} =~ ^[Yy]$ ]]
  then
    printf '\nRemoving database backup data: '
      docker run --rm -t ${DOCKER_OPTIONS} -v ${PG_DATA_BACKUP}:/volume_data alpine sh -c "rm -Rf /volume_data/*" >/dev/null
    printf 'Done'
  fi
  echo

  read -p "Would you like to delete the offline backups? " -n 1 -r
  echo
  if [[ ${REPLY} =~ ^[Yy]$ ]]
  then
    printf '\nRemoving backup data from temporary location: '
      rm -Rf ${PG_DUMP} ${PG_DUMP_ALTERED} >/dev/null
    printf 'Done'
  fi
  echo

  read -p "Would you like to delete the other files used for this script? " -n 1 -r
  echo
  if [[ ${REPLY} =~ ^[Yy]$ ]]
  then
    printf '\nRemoving backup data from temporary location: '
      rm -Rf ${PG_DUMP} ${PG_DUMP_ALTERED} >/dev/null
    printf 'Done'
  fi
  echo
}

############
### MAIN ###
############

ensure_target_image_exists

case "${1}" in
  # upgrade
  '-u')
    start_original_container
    extract_original_container_info
    wait_for_db ${CONTAINER}
    wait_for_success wait_for_container ${CONTAINER}
    create_backup
    stop_original_container
    temporarily_move_data
  ;;

  # recovery backup
  '-r')
    source ${SCRIPT_PG_ENV}
    source ${SCRIPT_ENV}
    clean_up_volume_before_import
  ;;

  *)
    help
  ;;
esac

start_new_container
wait_for_db ${TEMP_CONTAINER}
wait_for_success wait_for_container ${TEMP_CONTAINER}
import_data
drop_temporary_database
stop_and_remove_temporary_container
check_container_version
print_final_notes
clean_up
