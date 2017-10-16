#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

contains() {
    if [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]]
    then
        true
    else
        false
    fi
}

tf_prompt() {
    local exitcode=$?
    local DIR=
    local LOOK=${PWD%/}
    while [[ -n $LOOK ]]; do
        if [[ -d $LOOK/.tf ]]
        then
            DIR="$LOOK"
            break
        fi
        LOOK=${LOOK%/*}
    done
    if [[ -d /.tf ]]
    then
        DIR=/
    fi

    if [[ -z $DIR ]]
    then
        return
    fi

    local WORKSPACE_FILE=$DIR/.tf/.workspace
    local STACK_FILE=$DIR/.tf/.stack

    local ACCOUNTS_FILE=$DIR/accounts

    local CURRENT_WORKSPACE="<none>"
    local CURRENT_STACK="<none>"

    local VALID_WORKSPACES=

    ## Valid workspace
    if [[ -e $ACCOUNTS_FILE ]]
    then
        declare -A accounts
        while IFS=$'=' read -r -a anArray
        do
            VALID_WORKSPACES="$VALID_WORKSPACES ${anArray[0]}"
        done < $ACCOUNTS_FILE

        if [ -n "$TERRAFORM_WORKSPACE" ] && contains "$VALID_WORKSPACES" $TERRAFORM_WORKSPACE
        then
            CURRENT_WORKSPACE=$TERRAFORM_WORKSPACE
        elif [[ -e $WORKSPACE_FILE ]]
        then
            local WORKSPACE=`cat $WORKSPACE_FILE`
            if contains "$VALID_WORKSPACES" $WORKSPACE
            then
                CURRENT_WORKSPACE=$WORKSPACE
            fi
        fi

    fi

    ## Validate stack
    if [ -d $DIR/stacks ]
    then
        local VALID_STACKS=`find $DIR/stacks -maxdepth 1 -mindepth 1 -type d -printf "%f "`
        if [ -n "$TERRAFORM_STACK" ] && contains "$VALID_STACKS" $TERRAFORM_STACK
        then
            CURRENT_STACK=$TERRAFORM_STACK
        elif [[ -e $STACK_FILE ]]
        then
            local STACK=`cat $STACK_FILE`
            if contains "$VALID_STACKS" $STACK
            then
                CURRENT_STACK=$STACK
            fi
        fi
    fi

    echo -e "${YELLOW}($CURRENT_WORKSPACE/$CURRENT_STACK)${NC}"
}

