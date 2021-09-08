#!/bin/bash

############################################################
# TODO (in order of priority)                              #
############################################################
# - option to move the actual container image (including local changes) or just download the latest containter image from upstream
# - in case of multiple containers, create resources all at once (i.e.: network may be the same, you don't want to delete and recreate each time)
# - pv estimations are MOSTLY correct (generally within +/- 3%, more if volumes are very small)
# - improve logging: replace echo with log function and add verbosity levels
# - add an option to copy all the containers part of a network
# - check if published ports are available before initate the copy
# - implement autoselect compression algorthim

############################################################
# WON'T DO                                                 #
############################################################
# - delete container and volumes on local side -> Too risky
# - use a different name for the container on remote side -> Avoid mistakes

############################################################
# NOTES                                                    #
############################################################
# Sincerily apologies if I wrote this in bash. When I started, it was supposed to be a short script!

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
Description: helps moving stateful containers between docker contexts (i.e.: from local to remote host). Be sure you created valid contexts before using this script!
Options: [ -c | --compress (bzip2|gzip|none) ]
         [ -h | --help ]
         [ -k | --keep_running ]
         [ -l | --license ]
         [ -o | --override_origin DOCKER_CONTEXT ]
         [ -u | --unattended (d|s|a) ]
         [ -v | --verbose ]
         (pull|push)
         CONTAINER_NAMEs ...
         DOCKER_REMOTE_CONTEXT

Reference: to create a new docker context check here: https://docs.docker.com/engine/reference/commandline/context_create/
           example: $ docker context create --docker host=ssh://foo@bar foobar

-c | --compress OPTION
  Description: Use compression with the selected algorithm
  Default: bzip2
  Supported options: $(join_array_by ", " ${COMPRESS_ALGORITHM_ARGS})

-h | --help
  Description: Print this help message

-k | --keep_running
  Description: Keep local container running. If not set, the container will be stopped before starting the copying process and won't be started again on the local host
  Default: not enabled

-l | --license
  Description: Print MIT license

-o | --override_origin DOCKER_CONTEXT
  Description: This script assumes Docker you want to move containers between what is defined in your current ENV and an alternative context. With this option you can override the the DOCKER_CONTEXT.
  Default: not enabled

-u | --unattended OPTION
  Description: Auto-answer questions with the selected option for the questions: [D]elete and continue, [S]kip, [A]bort
  Default: not enabled
  Supported options: $(join_array_by ", " "${UNATTENDED_OPTION_ARGS[@]:1}")

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
  PARSED_ARGUMENTS=$(getopt -a -o hlkvc:u:o: --long help,license,keep_running,verbose,compress:,unattended:,override_origin: -- "${@}")
  VALID_ARGUMENTS=${?}
  if [ "${VALID_ARGUMENTS}" != "0" ]; then
    usage
    log "" 2 1
  fi

  # echo "PARSED_ARGUMENTS is ${PARSED_ARGUMENTS}"
  eval set -- "${PARSED_ARGUMENTS}"
  while :
  do
    case "${1}" in
      -h | --help)                  HELP=1                       ; shift   ;;
      -l | --license)               LICENSE=1                    ; shift   ;;
      -c | --compress)              COMPRESS_ALGORITHM="${2}"    ; shift 2 ;;
      -k | --keep_running)          KEEP_RUNNING=1               ; shift   ;;
      -u | --unattended)            UNATTENDED_OPTION="${2}"     ; shift 2 ;;
      -v | --verbose)               VERBOSE="/dev/stdout"        ; shift   ;;
      -o | --override_origin)       ORIGIN_DOCKER="${2}"         ; shift   ;;
      # -- means the end of the arguments; drop this, and break out of the while loop
      --) shift ; break ;;
      # If invalid options were passed, then getopt should have reported an error,
      # which we checked as VALID_ARGUMENTS when getopt was called...
      *) log "Unexpected option: ${1} - this should not happen. Did you forget to update the select case?" 99 ;;
    esac
  done

  if [[ -n "${HELP}" ]]; then
    log "$(usage)" 0 1
  fi

  if [[ -n "${LICENSE}" ]]; then
    log "$(license)" 0 1
  fi

  if [ ${#} -lt 3 ]; then
    log "$(usage)" 2 1
  else
    ACTION=${1} ; shift
    CONTAINERS=${*%${!#}} # container names
    REMOTE_DOCKER=${@:$#} # docker context

    validate_arguments
    set_compression_algorithm "${COMPRESS_ALGORITHM}"

    case ${ACTION} in
      'pull')
        DOCKER_ORIGIN=${REMOTE_DOCKER}
        DOCKER_DESTINATION=${ORIGIN_DOCKER} ;;
      'push')
        DOCKER_ORIGIN=${ORIGIN_DOCKER}
        DOCKER_DESTINATION=${REMOTE_DOCKER} ;;
      *) log "Unsupported action!" 99 ;;
    esac

    # just for some extra care
    [ "$(retrieve_docker_context "origin")" == "default" ] && [ "$(retrieve_docker_context "destination")" == "default" ] && log "FATAL: both contexts are set to default!"
  fi
}

function validate_arguments() {
  [[ ! " ${COMPRESS_ALGORITHM_ARGS[*]} " =~ " ${COMPRESS_ALGORITHM} " ]] && log "-c | --compress specified option is invalid: ${COMPRESS_ALGORITHM}. Valid options: $(join_array_by ", " "${COMPRESS_ALGORITHM_ARGS[@]}")" 1
  [[ ! " ${UNATTENDED_OPTION_ARGS[*]} " =~ " ${UNATTENDED_OPTION} " ]] && log "-u | --unattended specified option is invalid: ${UNATTENDED_OPTION}. Valid options: $(join_array_by ", " "${UNATTENDED_OPTION_ARGS[@]:1}")" 1
  [[ ! " ${ACTION_ARGS[*]} " =~ " ${ACTION} " ]] && log "specified action is invalid. Valid options: $(join_array_by ", " ${ACTION_ARGS[@]})" 1

  [[ "${REMOTE_DOCKER}" == "${ORIGIN_DOCKER}" ]] && log "origin and destination cannot be the same." 1

  [[ -n "${ORIGIN_DOCKER}" ]] && check_docker_context "${ORIGIN_DOCKER}"
}

function join_array_by { d=${1-} f=${2-}; if shift 2; then printf %s "$f" "${@/#/$d}"; fi; }

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
    echo -e "\n"'WARNING: You are running the script on an unsupported OS, use at your own risk!'"\n"'Waiting 5 seconds before continuing...'"\n"
    sleep 5

    return 1
  fi

  error_flag=0
  for (( i=0; i<${#commands[@]}; i++ ));
  do
    if ! command -v ${commands[${i}]} >/dev/null 2>&1 ; then
      error_flag=1
      log ${commands_instructions[${i}]}
    fi
  done
  [ ${error_flag} -eq 1 ] && goodbye

  ! [ "${BASH_VERSINFO:-0}" -ge 4 ] && log "This script needs at least Bash 4, please upgrade. You can install using your package manager or run the script from a different host" 1
}

function set_compression_algorithm() {
  compress_algorithm=${1}

  case ${compress_algorithm} in
    'bzip2')
      COMPRESS_BINARY=bzip2
      DECOMPRESS_TAR_STRING=xpjf ;;
    'gzip')
      COMPRESS_BINARY=gzip
      DECOMPRESS_TAR_STRING=xpzf ;;
    'none')
      COMPRESS_BINARY=cat
      DECOMPRESS_TAR_STRING=xpf ;;
    *) log "Unsupported algorithm!" 99 ;;
  esac
}

function goodbye() {
  suppress_message=${1}

  [[ ! -n "${suppress_message}" ]] && echo "Goodbye!"
  kill -s TERM ${TOP_PID}
}

function does_docker_work() {
  docker_actor=${1}
  docker_context=$(retrieve_docker_context ${docker_actor})

  log "        Checking if docker with context ${docker_context} works"
  env "$(set_docker_context ${docker_actor})" docker info > /dev/null 2>&1 || log "Couldn't use ${docker_context} context" 1
}

function check_docker_context() {
  docker_context=${1}

  log "        Checking if ${docker_context} exists"
  docker context inspect ${docker_context} 1>${VERBOSE}
  docker_context_status=${?}
  if [ ${docker_context_status} -eq 0 ] ; then
    log "        Context doesn't exist!" 1
  else
    return 0
  fi
}

function retrieve_docker_context() {
  docker_actor=${1}

  case ${docker_actor} in
    'origin')
      if [[ -n ${DOCKER_ORIGIN} ]]; then
        echo "${DOCKER_ORIGIN}"
      else
        echo "default"
      fi ;;
    'destination')
      if [[ -n ${DOCKER_DESTINATION} ]]; then
        echo "${DOCKER_DESTINATION}"
      else
        echo "default"
      fi ;;
    *)             log "Unsupported action!" 99 ;;
  esac
}

function set_docker_context() {
  docker_actor=${1}

  case ${docker_actor} in
    'origin')
      if [[ -n ${DOCKER_ORIGIN} ]]; then
        echo "DOCKER_CONTEXT=${DOCKER_ORIGIN}" # setting the local variable just if specified to avoid wrong overrides
      else
        echo "A=A" # drity hack to make env happy
      fi ;;
    'destination')
      if [[ -n ${DOCKER_DESTINATION} ]]; then
        echo "DOCKER_CONTEXT=${DOCKER_DESTINATION}" # setting the local variable just if specified to avoid wrong overrides
      else
        echo "A=A" # drity hack to make env happy
      fi ;;
    *) log "Unsupported action!" 99 ;;
  esac
}

function copy_volume() {
  docker_volume=${1}

  log "        Evaluating volume size"
  docker_volume_size=$(env "$(set_docker_context "origin")" docker run --rm -t -v ${docker_volume}:/volume_data alpine sh -c "apk -q --no-progress update && apk -q --no-progress add coreutils && du -sb /volume_data" | cut -f1 | xargs) || log "Couldn't evaluate volume size" 1

  log "        Copying content"
  env "$(set_docker_context "origin")" docker run --rm -v ${docker_volume}:/from alpine ash -c "cd /from ; tar cf - . " | pv -cN ${docker_volume} -s ${docker_volume_size} | ${COMPRESS_BINARY} | env $(set_docker_context "destination") docker run --rm -i -v ${docker_volume}:/to alpine ash -c "cd /to ; tar -${DECOMPRESS_TAR_STRING} - " || log "Couldn't copy volume content" 1
}

function create_volume() {
  docker_actor=${1}
  docker_volume=${2}

  log "        Creating ${docker_volume} volume on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker volume create ${docker_volume} 1>${VERBOSE} || log "Couldn't create volume on ${docker_actor} host" 1
}

function create_network() {
  docker_actor=${1}
  docker_network=${2}

  log "        Creating ${docker_network} network on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker network create ${docker_network} 1>${VERBOSE} || log "Couldn't create network on ${docker_actor} host" 1
}

function delete_container() {
  docker_actor=${1}

  # trying to stop the container before deleting, not triggering a failure because the container might be already stopped
  log "        Stopping ${CONTAINER} container on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker stop ${CONTAINER} 1>${VERBOSE}

  log "        Deleting ${CONTAINER} container on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker rm ${CONTAINER}   1>${VERBOSE} || log "Couldn't delete container on ${docker_actor} host" 1
}

function delete_volume() {
  docker_actor=${1}
  docker_volume=${2}

  log "        Deleting ${docker_volume} volume on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker volume rm ${docker_volume} 1>${VERBOSE} || log "Couldn't delete volume on ${docker_actor} host" 1
}

function delete_network() {
  docker_actor=${1}
  docker_network=${2}

  log "        Deleting ${docker_network} network on the ${docker_actor} host"
  env "$(set_docker_context ${docker_actor})" docker network rm ${docker_network} 1>${VERBOSE} || log "Couldn't delete network on ${docker_actor} host" 1
}

function check_if_container_exists() {
  docker_actor=${1}

  log "        Checking if ${CONTAINER} container exists on the ${docker_actor} host"

  env "$(set_docker_context ${docker_actor})" docker inspect --format="{{.State.Running}}" ${CONTAINER} 1>${VERBOSE} 2>/dev/null
  container_result=${?}
  if [ ${container_result} -ne 0 ]; then
    is_present=0
  else
    is_present=1
  fi

  return ${is_present}
}

function check_container_on_host_and_stop() {
  docker_actor=${1}

  check_if_container_exists "${docker_actor}"
  exist=${?}

  if [ ${exist} -eq 1 ]; then
    log "        ${CONTAINER} container already exists on the ${docker_actor} host..."
    prompt_options
    case ${?} in
      1) delete_container "destination";;
      2) log "        Skipping..." ; return 1 ;;
      3) goodbye ;;
    esac
  fi

  if [[ -n "${KEEP_RUNNING}" ]]; then
    log "        Leaving container on origin host running..."
  else
    env $(set_docker_context "origin") docker stop ${CONTAINER} 1>${VERBOSE} || log "Couldn't stop container on ${docker_actor} host" 1
  fi

  return 0
}

function check_if_network_exists() {
  docker_actor=${1}
  docker_network=${2}

  log "        Checking if ${docker_network} network exists on the ${docker_actor} host"
  is_present=$(env "$(set_docker_context ${docker_actor})" docker network ls -f "name=${docker_network}" --format "{{.Name}}" | wc -l)

  return ${is_present}
}

function check_if_volume_exists() {
  docker_actor=${1}
  docker_volume=${2}

  log "        Checking if ${docker_volume} volume exists on the ${docker_actor} host"
  is_present=$(env "$(set_docker_context ${docker_actor})" docker volume ls -f "name=${docker_volume}" --format "{{.Name}}" | wc -l)

  return ${is_present}
}

function copy_image() {
  docker_image=${1}

  log "        Checking if ${docker_image} already exists on destination host"
  env $(set_docker_context "destination") docker image inspect --format='{{.Config.Image}}' ${docker_image} 1>${VERBOSE}
  remote_image_status=${?}
  if [ ${remote_image_status} -eq 0 ] ; then
    log "        Image is available on the destination host!"
  else
    log "        Image doesn't exist on destination host, trying to pull ${docker_image} from upstream"
    env $(set_docker_context "destination") docker pull ${docker_image} 1>${VERBOSE}
    remote_pull_status=${?}
    if [ ${remote_pull_status} -eq 0 ] ; then
      log "        Image successfully pulled from the registry"
    else
      log "        Failed. Image needs to be pushed from this host to remote."
      log "        Copying container image: ${docker_image}"
      env $(set_docker_context "origin") docker save ${docker_image} | pv -cN ${docker_image} -s $(docker image inspect ${docker_image} --format='{{.Size}}') | bzip2 | env $(set_docker_context "destination") docker load
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
  networks=${1}

  for docker_network in $(echo ${networks})
  do
    if [ ${docker_network} == "bridge" ]; then
      log "        Skipping bridge network..."
    else
      check_if_network_exists "destination" ${docker_network}
      destination_status=${?}
      if [ ${destination_status} -eq 0 ] ; then
        create_network "destination" ${docker_network}
      else
        log "        ${docker_network} network exists on the destination host..."
        prompt_options
        case ${?} in
          1) delete_network "destination" ${docker_network}
             create_network "destination" ${docker_network} ;;
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
    for docker_volume in $(echo ${volumes})
    do
      check_if_volume_exists "destination" ${docker_volume}
      remote_status=${?}
      if [ ${remote_status} -eq 0 ] ; then
        create_volume "destination" ${docker_volume}
        copy_volume ${docker_volume}
      else
        prompt_options
        case ${?} in
          1) delete_volume "destination" ${docker_volume}
             create_volume "destination" ${docker_volume}
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

function check_compatibility() {
  # check for binds
  binds="$(env $(set_docker_context "origin") docker container inspect -f '{{ range .Mounts }}{{ if eq .Type "bind" }}{{ println .Source }}{{ end }}{{ end }}' ${CONTAINER})"

  if [[ -n "${binds}" ]]; then
    log "        WARNING: The following binds are associated to the container: $(join_array_by ', ' ${binds}). Be sure the destination host offers the same socks/files/directories"
  else
    log "        Great! No binds are associated to this container..."
  fi
}

function run_container() {
  log "        Run container: ${CONTAINER}"

  # find the docker command
  docker_command="$(env $(set_docker_context "origin") docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike ${CONTAINER})"

  # removing the detach option if it exists, so we avoid duplicated parameters
  docker_command=${docker_command/ -d / }
  docker_command=${docker_command/ --detach / }

  # inserting the detach option
  docker_command=${docker_command/docker run/docker run -d}

  # eval is necessary because some mixed single and double quotes in the command, especially in the entrypoint
  eval "$(set_docker_context "destination")" ${docker_command} 1>${VERBOSE}
}

function prompt_options() {
  message="What do you want to do? [D]elete and continue, [S]kip, [A]bort: "
  while true; do
    if [[ ! -n "${UNATTENDED_OPTION}" ]] ; then
      read -p $"${message}" response <${TTY}
    else
      response=$(echo ${UNATTENDED_OPTION})
    fi
    case ${response} in
        [Dd]* ) return 1 ;;
        [Ss]* ) return 2 ;;
        [Aa]* ) return 3 ;;
        * )     echo "Invalid choice." ;;
    esac
  done
}

function transfer_container() {
  log "  0/5 - Check container already exists on destination host and stop local container"
  check_container_on_host_and_stop "destination"
  if [ ${?} -eq 1 ] ; then
    log "        Interrupting process for this container"
    return 1
  fi

  log "  1/5 - Check for compatibility"
  check_compatibility

  # log "1/5 - Creating commit for your container"
  # docker commit ${CONTAINER} ${COMMIT} >/dev/null

  # iterate all the networks
  log "  2/5 - Creating networks"
  networks=$(env $(set_docker_context "origin") docker inspect -f '{{ range $k, $v := .NetworkSettings.Networks }}{{ $k }}{{ end }}' ${CONTAINER} 2>/dev/null)
  iterate_networks "${networks}"

  # iterate all the volumes
  log "  3/5 - Creating volumes"
  volumes=$(env $(set_docker_context "origin") docker container inspect -f '{{ range .Mounts }}{{ .Name }} {{ end }}' ${CONTAINER} 2>/dev/null)
  iterate_volumes "${volumes}"

  log "  4/5 - Pulling container image on the destination host"
  # copy_image ${COMMIT}
  copy_image $(env $(set_docker_context "origin") docker inspect --format='{{.Config.Image}}' ${CONTAINER})

  log "  5/5 - Run container"
  run_container
}

############################################################
# Traps                                                    #
############################################################
trap "exit 1" TERM

############################################################
# Global variables                                         #
############################################################
export TOP_PID=${$}

TTY=$(tty)
# COMMIT=$(openssl rand -hex 12)

VERBOSE="/dev/null" # defaulting unnecessary output to /dev/null
COMPRESS_ALGORITHM="bzip2"
COMPRESS_BINARY=""
DECOMPRESS_TAR_STRING=""
UNATTENDED_OPTION=""
ACTION=""
CONTAINERS=""
ORIGIN_DOCKER=""
REMOTE_DOCKER=""
DOCKER_ORIGIN=""
DOCKER_DESTINATION=""

############################################################
# Input validation                                         #
############################################################
COMPRESS_ALGORITHM_ARGS=(bzip2 gzip none)
UNATTENDED_OPTION_ARGS=('' D d S s A a)
ACTION_ARGS=(push pull)

############################################################
############################################################
# Main program                                             #
############################################################
############################################################
check_dependencies
parse_options ${@}

does_docker_work "origin"
does_docker_work "destination"

for CONTAINER in ${CONTAINERS}
do
  echo "Transferring: ${CONTAINER}"

  check_if_container_exists "origin"
  exist=${?}

  if [ ${exist} -eq 0 ]; then
    log "Couldn't find the specified container on the origin host!" 1
  else
    transfer_container
  fi
done
echo "All the containers have been successfully transferred!"
