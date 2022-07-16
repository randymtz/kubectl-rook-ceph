#!/usr/bin/env bash

# Copyright 2021 The Rook Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eEuo pipefail

####################################################################################################
# HELPER FUNCTIONS
####################################################################################################

function print_usage() {
  echo ""
  echo "DESCRIPTION"
  echo "kubectl rook-ceph provides common management and troubleshooting tools for Ceph."
  echo "USAGE"
  echo "  kubectl rook-ceph <main args> <command> <command args>"
  echo "MAIN ARGS"
  echo "  -h, --help                                : output help"
  echo "  -n, --namespace='rook-ceph'               : the namespace of the CephCluster"
  echo "  -o, --operator-namespace='rook-ceph'      : the namespace of the rook operator"
  echo " --context=<context_name>                   : the name of the Kubernetes context to be used"
  echo "COMMANDS"
  echo "  ceph <args>                               : call a 'ceph' CLI command with arbitrary args"
  echo "  rbd <args>                                : call a 'rbd' CLI command with arbitrary args"
  echo "  operator <subcommand>..."
  echo "    restart                                 : restart the Rook-Ceph operator"
  echo "    set <property> <value>                  : Set the property in the rook-ceph-operator-config configmap."
  echo "  mons                                      : output mon endpoints"
  echo "  debug <subcommand>..."
  echo "    node <svc> <nodeName> [--unset]         : set debug_<svc>=20 for pod/<svc> on nodeName."
  echo "                                            :   valid <svc> options: {mon,mgr,osd,mds}."
  echo "                                            :   --unset to remove override."
  echo "    svc <svc> [--unset]                     : set debug_<svc>=20"
  echo "                                            :   valid <svc> options: {mon,mgr,osd,mds}."
  echo "                                            :   --unset to remove override."
  echo "  rook <subcommand>..."
  echo "    version                                 : print the version of Rook"
  echo "    status                                  : print the phase and conditions of the CephCluster CR"
  echo "    status all                              : print the phase and conditions of all CRs"
  echo "    status <CR>                             : print the phase and conditions of CRs of a specific type, such as 'cephobjectstore', 'cephfilesystem', etc"
  echo "    purge-osd <osd-id> [--force]            : Permanently remove an OSD from the cluster. Multiple OSDs can be removed with a comma-separated list of IDs."
  echo ""
}

function fail_error() {
  print_usage >&2
  echo "ERROR: $*" >&2
  exit 1
}

# return failure if the input is not a flag
function is_flag() {
  [[ "$1" == -* ]]
}

# return failure if the input (a flag value) doesn't exist
function val_exists() {
  local val="$1"
  [[ -n "$val" ]]
}

# fail with an error if the value is set
function flag_no_value() {
  local flag="$1"
  local value="$2"
  val_exists "$value" && fail_error "Flag '$flag' does not take a value"
}

# Usage: parse_flags 'set_value_function' "$@"
#
# This is a reusable function that will parse flags from the beginning of the "$@" (arguments) input
# until a non-flag argument is reached. It then returns the remaining arguments in a global env var
# called REMAINING_ARGS. For each parsed flag, it calls the user-specified callback function
# 'set_value_function' to set a config value.
#
# When a flag is reached, calls 'set_value_function' with the parsed flag and value as args 1 and 2.
# The 'set_value_function' must take 2 args in this order: flag, value
# The 'set_value_function' must return non-zero if the flag needs a value and was not given one.
#   Can copy-paste this line to achieve the above:  val_exists "$val" || return 1 # val should exist
# The 'set_value_function' must return zero in all other cases.
# The 'set_value_function' should call 'fail_error' if a flag is specified incorrectly.
# The 'set_value_function' should enforce flags that should have no values (use 'flag_no_value').
# The 'set_value_function' should record the config specified by the flag/value if it is valid.
# When a non-flag arg is reached, stop parsing and return the remaining args in REMAINING_ARGS.
REMAINING_ARGS=()
function parse_flags() {
  local set_value_function="$1"
  shift # pop set_value_function arg from the arg list
  while (($#)); do
    arg="$1"
    shift
    FLAG=""
    VAL=""
    case "$arg" in
    --*=*)              # long flag with a value, e.g., '--namespace=my-ns'
      FLAG="${arg%%=*}" # left of first equal
      VAL="${arg#*=}"   # right of first equal
      val_exists "$VAL" || fail_error "Flag '$FLAG' does not specify a value"
      ;;
    --*) # long flag without a value, e.g., '--help' or '--namespace my-ns'
      FLAG="$arg"
      VAL=""
      ;;
    -*)                              # short flags
      if [[ "${#arg}" -eq 2 ]]; then # short flag without a value, e.g., '-h' or '-n my-ns'
        FLAG="$arg"
        VAL=""
      else                     # short flag with a value, e.g., '-nmy-ns', or '-n=my-ns'
        FLAG="${arg:0:2}"      # first 2 chars
        VAL="${arg:2:${#arg}}" # remaining chars
        VAL="${VAL#*=}"        # strip first equal from the value
      fi
      ;;
    *)
      # This is not a flag, so stop parsing and return the stored remaining args
      REMAINING_ARGS=("$arg" "$@") # store remaining args BEFORE shifting so we still have the
      break
      ;;
    esac
    is_flag "$VAL" && fail_error "Flag '$FLAG' value '$VAL' looks like another flag"
    # run the command with the current value, which may be empty
    if ! $set_value_function "$FLAG" "$VAL"; then
      # the flag needs a value, so grab the next arg to use as the value
      VAL="$1" || fail_error "Could not get value for flag '$FLAG'"
      shift
      # fail if the next arg looks like a flag and not a value
      is_flag "$VAL" && fail_error "Flag '$FLAG' value '$VAL' looks like another flag"
      # fail because the flag needs a value and value given is empty, e.g., --namespace ''
      val_exists "$VAL" || fail_error "Flag '$FLAG' does not specify a value"
      # run the command again with the next arg as its value
      if ! $set_value_function "$FLAG" "$VAL"; then
        fail_error "Flag '$FLAG' must have a value" # probably won't reach this, but just in case
      fi
    fi
  done
}

# call this at the end of a command tree when there should be no more inputs past a given point.
# Usage: end_of_command_parsing "$@" # where "$@" contains the remaining args
function end_of_command_parsing() {
  if [[ "$#" -gt 0 ]]; then
    fail_error "Extraneous arguments at end of input: $*"
  fi
}

####################################################################################################
# 'kubectl rook-ceph ceph ...' command
####################################################################################################

function run_ceph_command() {
  # do not call end_of_command_parsing here because all remaining input is passed directly to 'ceph'
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" exec deploy/rook-ceph-operator -- ceph "$@" --conf="$CEPH_CONF_PATH"
}

####################################################################################################
# 'kubectl rook-ceph rbd ...' command
####################################################################################################

function run_rbd_command() {
  # do not call end_of_command_parsing here because all remaining input is passed directly to 'ceph'
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" exec deploy/rook-ceph-operator -- rbd "$@" --conf="$CEPH_CONF_PATH"
}

####################################################################################################
# 'kubectl rook-ceph operator ...' commands
####################################################################################################

function run_operator_command() {
  if [ "$#" -eq 1 ] && [ "$1" = "restart" ]; then
    shift # remove the subcommand from the front of the arg list
    run_operator_restart_command "$@"
  elif [ "$#" -eq 3 ] && [ "$1" = "set" ]; then
    shift # remove the subcommand from the front of the arg list
    path_cm_rook_ceph_operator_config "$@"
  else
    fail_error "'operator' subcommand '$*' does not exist"
  fi
}

function run_operator_restart_command() {
  end_of_command_parsing "$@" # end of command tree
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" rollout restart deploy/rook-ceph-operator
}

function path_cm_rook_ceph_operator_config() {
  if [[ "$#" -ne 2 ]]; then
    fail_error "require exactly 2 subcommand: $*"
  fi
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" patch configmaps rook-ceph-operator-config --type json --patch "[{ op: replace, path: /data/$1, value: $2 }]"
}

####################################################################################################
# 'kubectl rook-ceph mon-endpoints' commands
####################################################################################################

function fetch_mon_endpoints() {
  end_of_command_parsing "$@" # end of command tree
  $TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get cm rook-ceph-mon-endpoints -o json | jq --monochrome-output '.data.data' | tr -d '"' | tr -d '=' | sed 's/[A-Za-z]*//g'
}

####################################################################################################
# 'kubectl rook-ceph debug ...' commands
####################################################################################################

function debug() {
  [[ -z "${1:-""}" ]] && fail_error "'debug <subcommand>' - Missing <subcommand>"
  subcommand=$1
  shift
  case "$subcommand" in
  node)
    [[ "$#" -eq 0 ]] && fail_error "'debug node' - Missing svc arg."
    run_debug_node "$@"
    ;;
  svc)
    run_debug_svc "$@"
    ;;
  *)
    fail_error "'debug' - invalid subcommand: '$subcommand'."
    ;;
  esac
}

function run_debug_node() {
  svc=$1
  [[ -z "${2:-""}" ]] && fail_error "'debug node' - Missing nodeName."
  node=$2
  nodeSvc=$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get pods -l app=rook-ceph-$svc -ojson | jq -r '[.items[].spec.nodeName]')
  template="
  {{- range .items -}}
    {{- if and (eq .kind \"Pod\") (eq .spec.nodeName \"$node\") (.metadata.labels.$svc) -}}
      {{.metadata.labels.$svc}}{{- \"\\n\" -}}
    {{- end -}}
  {{- end -}}"
  shift
  case "$svc" in
  mon|mgr|osd|mds)
    if [[ "${nodeSvc[*]}" =~ $node ]] && [ "$#" -eq 2 ] && [ "$2" = "--unset" ]; then
      id=$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get pods -o go-template="${template}")
      for id in $id
      do
        run_ceph_command config rm $svc.$id debug_$svc
      done
    elif [[ "$#" -eq 1 ]]; then
      id=$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get pods -o go-template="${template}")
      for id in $id
      do
        run_ceph_command config set $svc.$id debug_$svc 20/20
      done
    fi
    ;;
  *)
    fail_error "'debug' - invalid svc provided: $svc"
    ;;
  esac
}

function run_debug_svc() {
  [[ -z "${1:-""}" ]] && fail_error "'debug svc' Missing svc."
  svc=$1
  shift
  case "$svc" in
  mon|mgr|osd|mds)
    if [ "$#" -eq 1 ] && [ "$1" = "--unset" ]; then
      run_ceph_command config rm $svc debug_$svc
    else
      end_of_command_parsing "$@"
      run_ceph_command config set $svc debug_$svc 20/20
    fi
    ;;
  *)
    fail_error "'debug' - unsupported svc provided: $svc."
    ;;
  esac
}

####################################################################################################
# 'kubectl rook-ceph rook ...' commands
####################################################################################################

function rook_version() {
  [[ -z "${1:-""}" ]] && fail_error "Missing 'version' subcommand"
  subcommand="$1"
  shift # remove the subcommand from the front of the arg list
  case "$subcommand" in
  version)
    run_rook_version "$@"
    ;;
  status)
    run_rook_cr_status "$@"
    ;;
  purge-osd)
    run_purge_osd "$@"
    ;;
  *)
    fail_error "'rook' subcommand '$subcommand' does not exist"
    ;;
  esac
}

function run_rook_version() {
  end_of_command_parsing "$@" # end of command tree
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" exec deploy/rook-ceph-operator -- rook version
}

function run_rook_cr_status() {
  if [ "$#" -eq 1 ] && [ "$1" = "all" ]; then
    cr_list=$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get crd | awk '{print $1}' | sed '1d')
    echo "CR status"
    for cr in $cr_list; do
      echo "$cr": "$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get "$cr" -ojson | jq --monochrome-output '.items[].status')"
    done
  elif [[ "$#" -eq 1 ]]; then
    $TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get "$1" -ojson | jq --monochrome-output '.items[].status'
  elif [[ "$#" -eq 0 ]]; then
    $TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get cephclusters.ceph.rook.io -ojson | jq --monochrome-output '.items[].status'
  else
    fail_error "$# does not exist"
  fi
}

function run_purge_osd() {
  force_removal=false
  if [ "$#" -eq 2 ] && [ "$2" = "--force" ]; then
    force_removal=true
  fi
  mon_endpoints=$($TOP_LEVEL_COMMAND --namespace "$ROOK_CLUSTER_NAMESPACE" get cm rook-ceph-mon-endpoints -o jsonpath='{.data.data}' | cut -d "," -f1)
  ceph_secret=$($TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" exec deploy/rook-ceph-operator -- cat /var/lib/rook/"$ROOK_CLUSTER_NAMESPACE"/client.admin.keyring | grep "key" | awk '{print $3}')
  $TOP_LEVEL_COMMAND --namespace "$ROOK_OPERATOR_NAMESPACE" exec deploy/rook-ceph-operator -- sh -c "export ROOK_MON_ENDPOINTS=$mon_endpoints \
      ROOK_CEPH_USERNAME=client.admin \
      ROOK_CEPH_SECRET=$ceph_secret \
      ROOK_CONFIG_DIR=/var/lib/rook && \
    rook ceph osd remove --osd-ids=$1 --force-osd-removal=$force_removal"
}

####################################################################################################
# 'kubectl rook-ceph status' command
####################################################################################################
# Disabling it for now, will enable once it is ready implementation

# The status subcommand takes some args
# LONG_STATUS='false'

# # set_value_function for parsing flags for the status subcommand.
# function parse_status_flag () {
#   local flag="$1"
#   local val="$2"
#   case "$flag" in
#     "-l"|"--long")
#       flag_no_value "$flag" "$val"
#       LONG_STATUS='true'
#       ;;
#     *)
#       fail_error "Unsupported 'status' flag '$flag'"
#       ;;
#   esac
# }

# function run_status_command () {
#   REMAINING_ARGS=()
#   parse_flags 'parse_status_flag' "$@"
#   end_of_command_parsing "${REMAINING_ARGS[@]}" # end of command tree

#   if [[ "$LONG_STATUS" == "true" ]]; then
#     echo "LONG STATUS"
#   else
#     echo "SHORT STATUS"
#   fi
# }

####################################################################################################
# MAIN COMMAND HANDLER (is effectively main)
####################################################################################################

function run_main_command() {
  local command="$1"
  shift # pop first arg off the front of the function arg list
  case "$command" in
  ceph)
    run_ceph_command "$@"
    ;;
  rbd)
    run_rbd_command "$@"
    ;;
  operator)
    run_operator_command "$@"
    ;;
  mons)
    fetch_mon_endpoints "$@"
    ;;
  debug)
    debug "$@"
    ;;
  rook)
    rook_version "$@"
    ;;
  # status)
  #   run_status_command "$@"
  #   ;;
  *)
    fail_error "Unknown command '$command'"
    ;;
  esac
}

# Default values
: "${ROOK_CLUSTER_NAMESPACE:=rook-ceph}"
: "${ROOK_OPERATOR_NAMESPACE:=$ROOK_CLUSTER_NAMESPACE}"
: "${TOP_LEVEL_COMMAND:=kubectl}"

####################################################################################################
# MAIN: PARSE MAIN ARGS AND CALL MAIN COMMAND HANDLER
####################################################################################################

# set_value_function for parsing flags for the main rook-ceph plugin.
function parse_main_flag() {
  local flag="$1"
  local val="$2"
  case "$flag" in
  "-n" | "--namespace")
    val_exists "$val" || return 1 # val should exist
    ROOK_CLUSTER_NAMESPACE="${val}"
    ;;
  "-h" | "--help")
    flag_no_value "$flag" "$val"
    print_usage
    exit 0 # unique for the help flag; stop parsing everything and exit with success
    ;;
  "-o" | "--operator-namespace")
    val_exists "$val" || return 1 # val should exist
    ROOK_OPERATOR_NAMESPACE="${val}"
    ;;
  "--context")
    val_exists "$val" || return 1 # val should exist
    TOP_LEVEL_COMMAND="kubectl --context=${val}"
    ;;
  *)
    fail_error "Flag $flag is not supported"
    ;;
  esac
}

REMAINING_ARGS=()
parse_flags 'parse_main_flag' "$@"

if [[ "${#REMAINING_ARGS[@]}" -eq 0 ]]; then
  fail_error "No command to run"
fi

# Default value
CEPH_CONF_PATH="/var/lib/rook/$ROOK_CLUSTER_NAMESPACE/$ROOK_CLUSTER_NAMESPACE.config" # path of ceph config

run_main_command "${REMAINING_ARGS[@]}"
