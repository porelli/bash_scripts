#!/bin/bash

############################################################
# TODO (in order of priority)                              #
############################################################
# - allow pull instead of push
# - check if docker is reachable on both sides
# - options should be validated
# - add more compression options (bzip2 is slow)
# - bind mounts should at least raise a warning
# - option to move the actual container image (including local changes) or just download the latest containter image from upstream
# - when unattended, the message triggering the automatic action should still be displayed
# - pv estimations are MOSTLY correct (generally within +/- 3%)
# - improve logging: replace echo with log function and add verbosity levels
# - add an option to copy all the containers part of a network
# - implement autoselect compression algorthim

############################################################
# WON'T DO                                                 #
############################################################
# - delete container and volumes on local side -> Too risky
# - use a different name for the container on remote side -> Avoid mistakes

############################################################
# License                                                  #
############################################################
function license() {
  read -r -d '' license <<-EOF
MIT License

Copyright (c) 2021 Michele Porelli

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
  echo "${license}"
}

############################################################
# Help                                                     #
############################################################
function usage() {
  read -r -d '' usage <<-EOF
Usage: $(basename ${0})
Description: helps moving stateful containers to another host
Options: [ -c | --compress (bzip2/gzip/none) ]
         [ -h | --help ]
         [ -k | --keep_running ]
         [ -l | --license ]
         [ -u | --unattended (d/s/a) ]
         [ -v | --verbose ]
         LOCAL_CONTAINER_NAME ...
         REMOTE_HOST (ssh://user@remotehost)

-c | --compress OPTION
  Description: Use compression with the selected algorithm
  Default: bzip2
  Supported options: bzip2

-h | --help
  Description: Print this help message

-k | --keep_running
  Description: Keep local container running. If not set, the container will be stopped before starting the copying process and won't be started again on the local host
  Default: not enabled

-l | --license
  Description: Print MIT license

-u | --unattended OPTION
  Description: Auto-answer questions with the selected option
  Default: not enabled
  Supported options: [D]elete and continue, [S]kip, [A]bort

-v | --verbose
  Description: Enable verbose output. Error will be printed in any case
  Default: not enabled
EOF
  echo "${usage}"
}

############################################################
# Process the input options. Add options as needed.        #
############################################################
function parse_options() {
  PARSED_ARGUMENTS=$(getopt -a -o hlkvc:u: --long help,license,keep_running,verbose,compress:,unattended: -- "${@}")
  VALID_ARGUMENTS=${?}
  if [ "${VALID_ARGUMENTS}" != "0" ]; then
    usage
    log "" 2 1
  fi

  # defaulting unnecessary output to /dev/null
  VERBOSE="/dev/null"

  # echo "PARSED_ARGUMENTS is ${PARSED_ARGUMENTS}"
  eval set -- "${PARSED_ARGUMENTS}"
  while :
  do
    case "${1}" in
      -h | --help)         HELP=1                      ; shift   ;;
      -l | --license)      LICENSE=1                   ; shift   ;;
      -c | --compress)     COMPRESS_ALGORITHM="${2}"   ; shift 2 ;;
      -k | --keep_running) KEEP_RUNNING=1              ; shift   ;;
      -u | --unattended)   UNATTENDED_OPTION="${2}"    ; shift 2 ;;
      -v | --verbose)      VERBOSE="/dev/stdout"       ; shift   ;;
      # -- means the end of the arguments; drop this, and break out of the while loop
      --) shift ; break ;;
      # If invalid options were passed, then getopt should have reported an error,
      # which we checked as VALID_ARGUMENTS when getopt was called...
      *) log "Unexpected option: ${1} - this should not happen." 99 ;;
    esac
  done

  if [[ -n "${HELP}" ]]; then
    usage
    log "" 0 1
  fi

  if [[ -n "${LICENSE}" ]]; then
    license
    log "" 0 1
  fi

  if [ ${#} -lt 2 ]; then
    usage
    log "" 2 1
  else
    CONTAINERS=${*%${!#}} # container names
    REMOTE_DOCKER=${@:$#} # ssh://user@remotehost
  fi
}

function check_dependencies() {
  if [[ "${OSTYPE}" == "linux-gnu"* ]]; then
    commands=(docker pv getopt)
    commands_instructions=(
      "docker is not availble, please ensure it is installed and in your PATH"
      "pv is not availble, please ensure it is installed and in your PATH"
      "getopt is not availble, please ensure it is installed and in your PATH"
    )
  elif [[ "${OSTYPE}" == "darwin"* ]]; then
    commands=(docker pv /usr/local/opt/gnu-getopt/bin/getopt)
    commands_instructions=(
      "docker is not availble, please ensure it is installed and in your PATH"
      "pv is not availble, please install it with 'brew install pv'"
      "gnu-getopt is not availble, please install it with 'brew install gnu-getopt'"
    )

    export PATH="/usr/local/opt/gnu-getopt/bin:${PATH}"
  else
    echo -e "\n"'WARNING: You are running the script on an unsupported OS, use at your own risk!'"\n"
    sleep 5

    return 1
  fi

  for (( i=0; i<${#commands[@]}; i++ ));
  do
    if ! command -v ${commands[${i}]} >/dev/null 2>&1 ; then
      echo ${commands_instructions[${i}]}
    fi
  done
}

function goodbye() {
  suppress_message=${1}

  [[ ! -n "${suppress_message}" ]] && echo "Goodbye!"
  kill -s TERM ${TOP_PID}
}

function remote_docker() {
  docker_command="${@}"

  ssh ${ssh_target_host} "docker ${REMOTE_DOCKER}"
}

function copy_volume() {
  docker_volume=${1}

  log "        Evaluating volume size"
  docker_volume_size=$(docker run --rm -t -v ${docker_volume}:/volume_data alpine sh -c "apk -q --no-progress update && apk -q --no-progress add coreutils && du -sb /volume_data" | cut -f1 | xargs)

  log "        Copying content"
  docker run --rm -v ${docker_volume}:/from alpine ash -c "cd /from ; tar cf - . " | pv -cN ${docker_volume} -s ${docker_volume_size} | bzip2 | DOCKER_HOST=${REMOTE_DOCKER} docker run --rm -i -v ${docker_volume}:/to alpine ash -c 'cd /to ; tar -xpjf - '
}

function create_volume() {
  docker_volume=${1}

  log "        Creating remote ${docker_volume} volume on the remote host"
  DOCKER_HOST=${REMOTE_DOCKER} docker volume create ${docker_volume} 1>${VERBOSE} || log "Couldn't create volume on remote host" 1
}

function create_network() {
  docker_network=${1}

  log "        Creating remote ${docker_network} network on the remote host"
  DOCKER_HOST=${REMOTE_DOCKER} docker network create ${docker_network} 1>${VERBOSE} || log "Couldn't create network on remote host" 1
}

function delete_container() {
  log "        Stopping remote ${CONTAINER} container"
  DOCKER_HOST=${REMOTE_DOCKER} docker stop ${CONTAINER} 1>${VERBOSE} || log "Couldn't stop container on remote host" 1

  log "        Deleting remote ${CONTAINER} container"
  DOCKER_HOST=${REMOTE_DOCKER} docker rm ${CONTAINER}   1>${VERBOSE} || log "Couldn't delete container on remote host" 1
}

function delete_volume() {
  docker_volume=${1}

  log "        Deleting remote ${docker_volume} volume on the remote host"
  DOCKER_HOST=${REMOTE_DOCKER} docker volume rm ${docker_volume} 1>${VERBOSE} || log "Couldn't delete volume on remote host" 1
}

function delete_network() {
  docker_network=${1}

  log "        Deleting remote ${docker_network} network on the remote host"
  DOCKER_HOST=${REMOTE_DOCKER} docker network rm ${docker_network} 1>${VERBOSE} || log "Couldn't delete network on remote host" 1
}

function check_if_container_exists_locally() {
  log "        Checking if ${CONTAINER} container exists on the this host"
  is_present=$(docker ps -f "name=${CONTAINER}" --format "{{.Names}}" | wc -l)

  return ${is_present}
}

function check_if_container_exists_remotely() {
  log "        Checking if ${CONTAINER} container exists on the remote host"
  is_present=$(DOCKER_HOST=${REMOTE_DOCKER} docker ps -f "name=${CONTAINER}" --format "{{.Names}}" | wc -l)

  return ${is_present}
}

function check_remote_container_and_stop() {
  check_if_container_exists_remotely
  exist=${?}

  if [ ${exist} -eq 1 ]; then
    log "        ${CONTAINER} container already exists on the remote host..."
    prompt_options
    case ${?} in
      1) delete_container ;;
      2) log "        Skipping..." ; return 1 ;;
      3) goodbye ;;
    esac
  fi

  if [[ -n "${KEEP_RUNNING}" ]]; then
    log "        Leaving local container running..."
  else
    docker stop ${CONTAINER} 1>${VERBOSE} || log "Couldn't stop container on remote host" 1
  fi

  return 0
}

function check_if_network_exists() {
  docker_network=${1}

  log "        Checking if ${docker_network} network exists on the remote host"
  is_present=$(DOCKER_HOST=${REMOTE_DOCKER} docker network ls -f "name=${docker_network}" --format "{{.Name}}" | wc -l)

  return ${is_present}
}

function check_if_volume_exists() {
  docker_volume=${1}

  log "        Checking if ${docker_volume} volume exists on the remote host"
  is_present=$(DOCKER_HOST=${REMOTE_DOCKER} docker volume ls -f "name=${docker_volume}" --format "{{.Name}}" | wc -l)

  return ${is_present}
}

function copy_image() {
  docker_image=${1}

  log "        Checking if ${docker_image} already exists on remote host"
  DOCKER_HOST=${REMOTE_DOCKER} docker image inspect --format='{{.Config.Image}}' ${docker_image} 1>${VERBOSE}
  remote_image_status=${?}
  if [ ${remote_image_status} -eq 0 ] ; then
    log "        Image is available on the remote host!"
  else
    log "        Image doesn't exist on remote host, trying to pull ${docker_image} from upstream"
    DOCKER_HOST=${REMOTE_DOCKER} docker pull ${docker_image} 1>${VERBOSE}
    remote_pull_status=${?}
    if [ ${remote_pull_status} -eq 0 ] ; then
      log "        Image successfully pulled from the registry"
    else
      log "        Failed. Image needs to be pushed from this host to remote."
      log "        Copying container image: ${docker_image}"
      docker save ${docker_image} | pv -cN ${docker_image} -s $(docker image inspect ${docker_image} --format='{{.Size}}') | bzip2 | DOCKER_HOST=${REMOTE_DOCKER} docker load
    fi
  fi
}

function log() {
  message="${1}"
  exit_code="${2}"
  suppress_exit_message="${3}"

  echo "${message}"
  [[ -n "${exit_code}" ]] && goodbye ${suppress_exit_message}
}

function iterate_networks() {
  echo ${networks} | while read docker_network
  do
    if [ ${docker_network} == "bridge" ]; then
      log "        Skipping bridge network..."
    else
      check_if_network_exists ${docker_network}
      remote_status=${?}
      if [ ${remote_status} -eq 0 ] ; then
        create_network ${docker_network}
      else
        log "        ${docker_network} network exists on the remote host..."
        prompt_options
        case ${?} in
          1) delete_network ${docker_network}
             create_network ${docker_network} ;;
          2) log "        Skipping..." ;;
          3) goodbye ;;
        esac
      fi
    fi
  done
}

function iterate_volumes() {
  volumes=${1}

  if [[ -n "${volumes}" ]]; then
    echo ${volumes} | while read docker_volume
    do
      check_if_volume_exists ${docker_volume}
      remote_status=${?}
      if [ ${remote_status} -eq 0 ] ; then
        create_volume ${docker_volume}
        copy_volume ${docker_volume}
      else
        prompt_options
        case ${?} in
          1) delete_volume ${docker_volume}
             create_volume ${docker_volume}
             copy_volume ${docker_volume} ;;
          2) log "        Skipping..." ;;
          3) goodbye ;;
        esac
      fi
    done
  else
    log "        No volumes are part of this container..."
  fi
}

function run_container() {
  log "        Run container: ${CONTAINER}"

  # find the docker command
  docker_command="$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike ${CONTAINER})"

  # removing the detach option if it exists, so we avoid duplicated parameters
  docker_command=${docker_command/ -d / }
  docker_command=${docker_command/ --detach / }

  # inserting the detach option
  docker_command=${docker_command/docker run/docker run -d}

  # eval is necessary because some mixed single and double quotes in the command, especially in the entrypoint
  DOCKER_HOST=${REMOTE_DOCKER} eval ${docker_command} 1>${VERBOSE}
}

function prompt_options() {
  while true; do
    if [[ ! -n "${UNATTENDED_OPTION}" ]] ; then
      read -p $'What do you want to do? [D]elete and continue, [S]kip, [A]bort: ' response <${TTY}
    else
      response=$(echo ${UNATTENDED_OPTION})
    fi
    case ${response} in
        [Dd]* ) return 1;;
        [Ss]* ) return 2;;
        [Aa]* ) return 3;;
        * ) echo "Please answer [D]elete and continue, [S]kip, [A]bort";;
    esac
  done
}

function transfer_container() {
  log "  1/5 - Check container already exists on remote host and stop local container"
  check_remote_container_and_stop
  if [ ${?} -eq 1 ] ; then
    log "        Interrupting process for this container"
    return 1
  fi

  # log "1/5 - Creating commit for your container"
  # docker commit ${CONTAINER} ${COMMIT} >/dev/null

  # iterate all the networks
  log "  2/5 - Creating networks"
  networks=$(docker inspect ${CONTAINER} --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  iterate_networks ${networks}

  # iterate all the volumes
  log "  3/5 - Creating volumes"
  volumes=$(docker inspect -f '{{ (index .Mounts 0).Name }}' ${CONTAINER} 2>/dev/null)
  iterate_volumes ${volumes}

  log "  4/5 - Pulling image on the remote host"
  # copy_image ${COMMIT}
  copy_image $(docker inspect --format='{{.Config.Image}}' ${CONTAINER})

  log "  5/5 - Run container"
  run_container
}

############################################################
# Traps and global variables                               #
############################################################
trap "exit 1" TERM
export TOP_PID=${$}

TTY=$(tty)
# COMMIT=$(openssl rand -hex 12)

############################################################
############################################################
# Main program                                             #
############################################################
############################################################
check_dependencies
parse_options ${@}

for CONTAINER in ${CONTAINERS}
do
  echo "Transferring: ${CONTAINER}"

  check_if_container_exists_locally
  exist=${?}

  if [ ${exist} -eq 0 ]; then
    log "Couldn't find the specified container on this host!" 1
  else
    transfer_container
  fi
done
