#!/bin/bash
# Force bash to handle uninitialized variables and errors
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# NOTE: 'set -eE' exits on failure, good for debug but we want to handle errors
#set -eEuo pipefail
set -uo pipefail
if [ -t 0 ]; then
    declare -r STDIN=""
else 
    declare -r STDIN=$(</dev/stdin)
fi
