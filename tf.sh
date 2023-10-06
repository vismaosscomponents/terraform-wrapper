#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

## utility
contains() {
    if [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]]
    then
        true
    else
        false
    fi
}

context_stack() {
    if [ -n "$TERRAFORM_STACK" ]; then
        return 0
    fi

    if [ ! -e $STACK_FILE ]; then
        echo -e "${RED}Stack file doesn't exist!${NC}"
        return 1
    fi

    export TERRAFORM_STACK=$(cat $STACK_FILE)

    if [ -z "$TERRAFORM_STACK" ]; then
        echo -e "${RED}Missing value from stack file!${NC}"
        return 1
    fi

    return 0
}

context_workspace() {
    if [ -n "$TERRAFORM_WORKSPACE" ]; then
        export AWS_PROFILE=$TERRAFORM_WORKSPACE
        return 0
    fi

    if [ ! -e $WORKSPACE_FILE ]; then
        echo -e "${RED}Workspace file doesn't exist!${NC}"
        return 1
    fi

    export TERRAFORM_WORKSPACE=$(cat $WORKSPACE_FILE)
    export AWS_PROFILE=$TERRAFORM_WORKSPACE
    if [ -z "$TERRAFORM_WORKSPACE" ]; then
        echo -e "${RED}Missing value from workspace file!${NC}"
        return 1
    fi

    return 0
}

context() {
    context_stack
    if [ $? -eq 1 ]; then
        exit 1
    fi
    
    context_workspace
    if [ $? -eq 1 ]; then
        exit 1
    fi

    if [ $1 ] || [ "$TF_WRAPPER_DEBUG" == "true" ]
    then
        echo -e "Using stack:     ${GREEN}${TERRAFORM_STACK}${NC}"
        echo -e "Using workspace: ${GREEN}${TERRAFORM_WORKSPACE}${NC}"
    fi
}

install_required() {
    if [ "$TF_WRAPPER_DEBUG" == "true" ]; then
        echo -e "${YELLOW}Running install_required${NC}"
    fi

    if [ "$(which tfswitch)" == "" ]; then
        echo "tfswitch is not installed...\nInstalling latest version of tfswitch"
        curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh -o /tmp/install.sh && chmod 755 /tmp/install.sh 
        /tmp/install.sh -b $HOME/bin && rm /tmp/install.sh
        echo "${GREEN}Tfswitch has been installed${NC}"
    elif [ "$TF_WRAPPER_DEBUG" == "true" ]; then
         echo -e "${GREEN}tfswitch is installed${NC}"
    fi
}

search_up() {
    if [ "$TF_WRAPPER_DEBUG" == "true" ]; then
        echo -e "${YELLOW}Running search_up${NC}"
    fi

    local LOOK=${PWD%/}
    while [[ -n $LOOK ]]; do
        [[ -d $LOOK/.tf ]] && {
            DIR="$LOOK"
            return
        }
        LOOK=${LOOK%/*}
    done
    if [[ -d /.tf ]]
    then
        DIR=/
    fi
}

terraform_version_select() {
    if [ "$TF_WRAPPER_DEBUG" == "true" ]; then
        echo -e "${YELLOW}Running terraform_version_select${NC}"
    fi

    # Define which terraform version to use
    context_stack
    TF_VERSION_FILE=$DIR/stacks/$TERRAFORM_STACK/terraform.version
    TF_VERSION_FILE_ROOT=$DIR/terraform.version

    #TF_VERSION_FILE needs to match the SEMVAR MAJOR.MINOR.PATCH 
    if [ -f "$TF_VERSION_FILE" ]; then
        TF_VERSION=`head -n 1 $TF_VERSION_FILE`
    elif [ -f "$TF_VERSION_FILE_ROOT" ]; then
        TF_VERSION=`head -n 1 $TF_VERSION_FILE_ROOT`
    else
        (>&2 echo -e "${RED}No version of terraform has been specified. Create first a terraform.version file with a proper semver${NC}")
        exit 1
    fi

    if ! [[ $TF_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "The version specified in the 'terraform.version', doesn't match semver MAJOR.MINOR.PATCH"
        exit 1
    fi

    if [ "$(terraform version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" != "$TF_VERSION" ]; then
        echo -e "${YELLOW}Terraform couldn't be found or it didn't match the $TF_VERSION${NC} version"
        tfswitch "$TF_VERSION"
    fi
}

read_accounts() {
    if [ "$TF_WRAPPER_DEBUG" == "true" ]; then
        echo -e "${YELLOW}Running read_accounts${NC}"
    fi

    ACCOUNTS_FILE=$DIR/accounts
    if ! [[ -e $ACCOUNTS_FILE ]]; then
        (>&2 echo -e "${RED}$ACCOUNTS_FILE file missing.${NC}")
        exit 1
    fi

    while IFS=$'=' read -r -a anArray
    do
        accounts[${anArray[0]}]=`echo ${anArray[1]} | sed s/[^0-9]//`
    done < $ACCOUNTS_FILE
}

bootstrap() {
    if [ "$TF_WRAPPER_DEBUG" == "true" ]; then
        echo -e "Running in ${YELLOW}debug${NC} mode"
        echo -e "${YELLOW}Running bootstrap${NC}"
    fi

    install_required
    search_up

    if [ ! -d "$DIR/.tf" ]; then
        mkdir -p $DIR/.tf
    fi

    read_accounts

    # Setup variables used throughout the script
    WORKSPACE_FILE=$DIR/.tf/.workspace
    STACK_FILE=$DIR/.tf/.stack
    VALID_STACKS=$(find $DIR/stacks -maxdepth 1 -mindepth 1 -type d -printf "%f " | tr ' ' '\n' | sort | tr '\n' ' ')

    # Local configuration file, for some api keys
    if [ -f "$DIR/terraform.tfvars" ]; then
        EXTRA_VAR_FILE=-var-file=../../terraform.tfvars
    fi

    terraform_version_select
}

## workspace

workspace() {
    WORKSPACE_SUBCOMMAND=$1
    shift
    case $WORKSPACE_SUBCOMMAND in
        select)
            workspace_select "$@"
            ;;
        list)
            context_workspace
            echo -e "Currently using workspace: [${GREEN}$TERRAFORM_WORKSPACE${NC}]"
            echo -e "Available workspaces are:  [${YELLOW}${!accounts[@]}${NC}]" 
            ;;
        help)
            echo -e "Usage:  ${YELLOW}$TF_BIN_NAME workspace <subcommand>${NC}
Available subcommands:

select      Selects the working workspace
list        List the selected workspace and available workspaces
help        Prints available workspace subcommands

${YELLOW}To initialize an already selected workspace use '$TF_BIN_NAME init'${NC}"
            ;;
        *)
            echo -e "The command ${RED}$WORKSPACE_SUBCOMMAND${NC} is not available.\nUse '${YELLOW}$TF_BIN_NAME workspace help${NC}' to see the available command"
            ;;
    esac
    return $?
}

workspace_init() {
    if (! stack_verify) then
        echo -e "${RED}An error occured while verifying the stack${NC}"
        return 1
    fi
    
    if [ -z $TF_USE_CURRENT_PROFILE ]
    then
        export AWS_PROFILE=$TERRAFORM_WORKSPACE
    fi
    STACK_DIR=$DIR/stacks/$TERRAFORM_STACK

    rm -rf $STACK_DIR/.terraform $STACK_DIR/terraform.tfstate.d $STACK_DIR/.terraform.lock.hcl
    BACKEND_BUCKET="terraform-state-${accounts[${TERRAFORM_WORKSPACE}]}"
    STATE_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/terraform-state\`].{keyid:TargetKeyId}" --output text)

    terraform -chdir=$STACK_DIR init -backend-config="bucket=${BACKEND_BUCKET}" -backend-config="key=stacks/$TERRAFORM_STACK" -backend-config="encrypt=true" -backend-config="kms_key_id=${STATE_KEY_ID}"
    set +e
    terraform -chdir=$STACK_DIR workspace select $TERRAFORM_WORKSPACE
    if [ $? != 0 ]
    then
        terraform -chdir=$STACK_DIR workspace new $TERRAFORM_WORKSPACE
        terraform -chdir=$STACK_DIR workspace select $TERRAFORM_WORKSPACE
    fi
    set -e
    return $?
}

workspace_verify() {
    workspace_valid() {
     if [ ${accounts[$TERRAFORM_WORKSPACE]+abc} ]; then
        echo -e "Current workspace: ${GREEN}$TERRAFORM_WORKSPACE${NC}"
        workspace_init
    else
        (>&2 echo -e "${RED}Invalid workspace '$TERRAFORM_WORKSPACE'.\n$TF_BIN_NAME workspace select <workspace>\nValid workspaces: [${!accounts[@]}].${NC}")
        return 1
    fi   
    }

    # Keeping this if for automation purposes via environment variables
    if [ -n "$TERRAFORM_WORKSPACE" ]; then
        if (! workspace_valid "env") then
            return 1
        fi
    else
        context_workspace
        if (! workspace_valid ".tf/.workspace") then
            return 1
        fi
    fi
    return 0
}

workspace_select() {
    if [ -n "$1" ] && [ ${accounts[$1]+abc} ]
    then
        context_workspace
        if [ "$1" != "$TERRAFORM_WORKSPACE" ]; then
            export TERRAFORM_WORKSPACE=$1
            echo $TERRAFORM_WORKSPACE > $WORKSPACE_FILE
            echo -e "${YELLOW}Switching workspace to $TERRAFORM_WORKSPACE${NC}"
            workspace_verify
        else
            echo -e "Already on workspace ${GREEN}$TERRAFORM_WORKSPACE${NC}"
        fi
    else
        (>&2 echo -e "${RED}workspace '$1' is invalid. Usage: $TF_BIN_NAME workspace accounts[@]}].${NC}")
        return 1
    fi
    return 0
}

## stack

stack() {
    STACK_SUBCOMMAND=$1
    shift
    case $STACK_SUBCOMMAND in
        select)
            stack_select "$@"
            ;;
        list)
            context_stack
            echo -e "Currently using stack: [${GREEN}$TERRAFORM_STACK${NC}]"
            echo -e "Available stacks are:  [${YELLOW}$VALID_STACKS${NC}]" 
            ;;
        help)
            echo -e "Usage:  ${YELLOW}$TF_BIN_NAME stack <subcommand>${NC}
Available subcommands:

select      Selects the working stack
list        List the selected stack and available stacks
help        Prints available stack subcommands" 
            ;;
        *)
            echo -e "The command ${RED}$STACK_SUBCOMMAND${NC} is not available.\nUse '${YELLOW}$TF_BIN_NAME stack help${NC}' to see the available command"
            ;;
    esac
    return $?
}

stack_verify() {
    stack_valid(){
        if contains "$VALID_STACKS" $TERRAFORM_STACK
        then
            echo -e "Current stack: ${GREEN}$TERRAFORM_STACK${NC}"
        else
            (>&2 echo -e "${RED}Invalid stack '$TERRAFORM_STACK'.\n$TF_BIN_NAME stack select [$VALID_STACKS]${NC}")
            return 1
        fi
        return 0
    }

    # Keeping this if for automation purposes via environment variables
    if [ -n "$TERRAFORM_STACK" ]; then
        if (! stack_valid "env") then
            return 1
        fi
    else
        context_stack
        if (! stack_valid ".tf/.stack") then
            return 1
        fi
    fi


    stack_global=$DIR/stacks/$TERRAFORM_STACK/global.symlink.tf
    stack_backend=$DIR/stacks/$TERRAFORM_STACK/backend.symlink.tf
    if [ -f $stack_global ]; then
        rm $stack_global
    fi

    if [ ! -h $stack_global ]; then
        ln -s $DIR/global.tf  $stack_global
    fi
    
    if [ -f $stack_backend ]; then
        rm $stack_backend
    fi
    
    if [ ! -h $stack_backend ]; then
        ln -s $DIR/backend.tf $stack_backend 
    fi
    return $?
}

stack_select() {
    if contains "$VALID_STACKS" $1
    then
        echo -e "${YELLOW}Switching stack to $1.${NC}"
        export TERRAFORM_STACK=$1
        echo $TERRAFORM_STACK > $STACK_FILE
        echo -e "${GREEN}Stack switched to $TERRAFORM_STACK.${NC}"
    else
        (>&2 echo -e "${RED}stack '$1' is invalid. Usage: $TF_BIN_NAME stack [$VALID_STACKS]${NC}")
        return 1
    fi

    terraform_version_select
    return $?
}

## backend
backend() {
    if [ ${#@} -lt 1 ]; then
        echo -e "${RED}No command has been provided for backend.\nUsual terraform commands can be used.${NC}"
        echo -e "${YELLOW}Usage: $TF_BIN_NAME backend <terraform_command>${NC}"
        return 1
    fi
    context_workspace

    echo -e "Using directory:   ${GREEN}state-management${NC}"
    echo -e "Current workspace: ${GREEN}$TERRAFORM_WORKSPACE${NC}"
    backend=$DIR/state-management/backend.symlink.tf
    if [ -f $backend ]; then
        rm $backend
    fi

    if [ ! -h $backend ]; then
        ln -s $DIR/backend.tf  $backend
    fi

    BACKEND_BUCKET="terraform-state-${accounts[${TERRAFORM_WORKSPACE}]}"
    STATE_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/terraform-state\`].{keyid:TargetKeyId}" --output text)
    if [ "$1" == "init" ]; then
        rm -rf .terraform terraform.tfstate.d .terraform.lock.hcl
        terraform -chdir=$DIR/state-management $1 ${@:2} -backend-config="bucket=${BACKEND_BUCKET}" -backend-config="key=backend/terraform.tfstate" -backend-config="encrypt=true" -backend-config="kms_key_id=${STATE_KEY_ID}"
    else
        terraform -chdir=$DIR/state-management "$@"
    fi
    return $?
}

## dependencies
dependencies() {
    ADD_STATUS=d
    if [ "x$1" = "xstatus" ]
    then
        ADD_STATUS=1
    fi
    # check dependencies between modules
    echo -e "digraph {
    compound = \"true\"
    newrank = \"true\"
    node[style=filled]\n"
    for stack in $VALID_STACKS
    do
        ATTRIBUTES=
        if [ "$ADD_STATUS" = "1" ]
        then
            COLOR=red
            set +e
            result=$(export TERRAFORM_STACK=$stack; $0 plan -detailed-exitcode 2> /dev/null)
            EXIT_CODE=$?
            set -e
            if [[ $EXIT_CODE == 2 ]]
            then
                COLOR=yellow
            elif [[ $EXIT_CODE == 0 ]]
            then
                COLOR=green
            fi
            if [[ -n "$ATTRIBUTES" ]]
            then
                ATTRIBUTES=${ATTRIBUTES},
            fi
            ATTRIBUTES=${ATTRIBUTES}fillcolor=${COLOR}
        fi
        echo -e \"$stack\"[$ATTRIBUTES]
    done
    grep \\\"terraform_remote_state $DIR/stacks/*/*.tf | sed -e 's/.*\/stacks\///; s/\/.*terraform_remote_state//; s/["{]//g; s/ /" -> "/; s/\s\+$/"/; s/^/"/'

    echo -e "}"
}

## chamber
chamber() {
    export AWS_REGION=eu-west-1
    COMMAND=$1
    case $COMMAND in
        exec|help|history|list)
            chamber "$@"
            return $?
            ;;
        read|write)
            shift
            SERVICE=$1
            shift
            export CHAMBER_KMS_KEY_ALIAS=alias/$SERVICE-configuration-secrets
            chamber $COMMAND $SERVICE "$@"
            return $?
            ;;
    esac
    return 1
}

## conf
conf() {
    PREFIX=$1
    shift
    COMMAND=$1
    case $COMMAND in
        diff)
            shift
            FILE=$1
            shift
            if [ -z $FILE ]
            then
                (>&2 echo -e "${RED}Specify a file name${NC}")
                exit 1
            fi
            aws s3 cp s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/$FILE - | diff $DIR/configurationfiles/$PREFIX/$TERRAFORM_WORKSPACE/$FILE "$@" -- -
            ;;
        cp)
            shift
            CONF_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/$PREFIX-configuration\`].{keyid:TargetKeyId}" --output text)
            aws s3 cp --sse "aws:kms" --sse-kms-key-id "${CONF_KEY_ID}" $DIR/configurationfiles/$PREFIX/$TERRAFORM_WORKSPACE/ s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/ --recursive "$@"
            ;;
        sync)
            shift
            CONF_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/$PREFIX-configuration\`].{keyid:TargetKeyId}" --output text)
            aws s3 sync --sse "aws:kms" --sse-kms-key-id "${CONF_KEY_ID}" --delete $DIR/configurationfiles/$PREFIX/$TERRAFORM_WORKSPACE/ s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/
            ;;
        *)
            echo "Files on S3:"
            aws s3 ls --recursive s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/
            echo "Sync (dryrun):"
            aws s3 sync --delete --dryrun $DIR/configurationfiles/$PREFIX/$TERRAFORM_WORKSPACE/ s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/
            ;;
    esac
    return $?
}

## main
main() {
    bootstrap

    TF_COMMAND=$1
    shift
    case $TF_COMMAND in
        deps)
            context
            dependencies "$@"
            ;;
        conf)
            context
            conf "$@"
            ;;
        chamber)
            chamber "$@"
            ;;
        init)
            workspace_verify
            ;;
        backend)
            backend "$@"
            ;;
        apply)
            context
            export TF_CLI_ARGS="-var-file=$DIR/envvars/${TERRAFORM_WORKSPACE}.tfvars -var-file=$DIR/global.tfvars $EXTRA_VAR_FILE -input=false -auto-approve=false"
            terraform -chdir=$DIR/stacks/$TERRAFORM_STACK $TF_COMMAND "$@"
            ;;
        plan|destroy|import|refresh|console)
            context
            export TF_CLI_ARGS="-var-file=$DIR/envvars/${TERRAFORM_WORKSPACE}.tfvars -var-file=$DIR/global.tfvars $EXTRA_VAR_FILE -input=false"
            terraform -chdir=$DIR/stacks/$TERRAFORM_STACK $TF_COMMAND "$@"
            ;;
        get|validate|state|graph|fmt|show|taint|untaint|version|output|force-unlock|metadata|login|logout|providers)
            context
            terraform -chdir=$DIR/stacks/$TERRAFORM_STACK $TF_COMMAND "$@"
            ;;
        workspace)
            workspace "$@"
            ;;
        stack)
            stack "$@"
            ;;
        ctx)
            context true
            ;;
        help)
            echo -e "${YELLOW}Available $TF_BIN_NAME commands\n$TF_BIN_NAME has priority over terraform${NC}"
            echo "
  deps          Displays dependencies between stacks
  conf          Interact with S3 configuration buckets
  chamber       Run chamber commands
  init          Forcefully initialize a workspace
  ctx           Show selected stack and workspace 
  workspace     Wraps workspaces around 'accounts' file
  backend       Run normal terraform commands on the terraform state bucket
  stack         Manage stacks for the selected workspace"
            echo -e "\n${YELLOW}Available terraform commands${NC}\n"
            terraform -help
            ;;
        *)
            (>&2 echo -e "${RED}Command '$TF_COMMAND' is not supported. Use '$TF_BIN_NAME help' for more information${NC}")
            echo -e "${YELLOW}$TF_BIN_NAME is compatible with terrafom version ~>1.5. If you require a command that is above this version, please raise an issue at https://github.com/vismaosscomponents/terraform-wrapper${NC}"
            ;;
    esac

    exit $?
}

## Running script
# Get binary name for output purposes 
TF_BIN_NAME=$(echo $0 | rev | cut -d '/' -f1 | rev)
# globally scoped
declare -A accounts 
main "$@"
## End of running script
