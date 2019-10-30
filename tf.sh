#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function usage {
    echo "Usage: $0 <stack> <terraform command>"
    exit 1;
}

contains() {
    if [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]]
    then
        true
    else
        false
    fi
}

# Login with Privileged User Management
# 1st parameter: target AWS profile
# 2nd parameter: target AWS account id
function login() {
        set +e
        EXIT_CODE=$(winpty --version 2>&1 > /dev/null)
        EXIT_CODE=$?
        set -e
        PTY=
        if [[ $EXIT_CODE == 0 ]]
        then
            PTY="winpty"
        fi

        PYTHON=python
        set +e
        EXIT_CODE=$(python3 --version 2>&1 > /dev/null)
        EXIT_CODE=$?
        set -e
        if [[ $EXIT_CODE == 0 ]]
        then
            PYTHON="python3"
        fi

        $PTY $PYTHON $TFDIR/pum-aws.py --profile $1 --account $2
}

function setup_workspace {
    cd $DIR/stacks/$TERRAFORM_STACK
    CURRENT_WORKSPACE=`terraform-0.11 workspace show`
    if [ $CURRENT_WORKSPACE != $TERRAFORM_WORKSPACE ]
    then
        init_workspace
    fi
}

function init_workspace {
    if [ -z $TF_USE_CURRENT_PROFILE ]
    then
        export AWS_PROFILE=$TERRAFORM_WORKSPACE
    fi
    cd $DIR/stacks/$TERRAFORM_STACK

    rm -rf .terraform/environment .terraform/terraform.tfstate
    BACKEND_BUCKET="terraform-state-${accounts[${TERRAFORM_WORKSPACE}]}"
    STATE_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName==\`alias/terraform-state\`].{keyid:TargetKeyId}" --output text)
    terraform-0.11 init -backend-config="bucket=${BACKEND_BUCKET}" -backend-config="key=stacks/$TERRAFORM_STACK" -backend-config="encrypt=true" -backend-config="kms_key_id=${STATE_KEY_ID}"
    set +e
    terraform-0.11 workspace select $TERRAFORM_WORKSPACE
    if [ $? != 0 ]
    then
        terraform-0.11 workspace new $TERRAFORM_WORKSPACE
        terraform-0.11 workspace select $TERRAFORM_WORKSPACE
    fi
    set -e
}

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  TFDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$TFDIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
TFDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

DIR=

search_up() {
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

search_up

#SOURCE="${BASH_SOURCE[0]}"
#while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
#  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
#  SOURCE="$(readlink "$SOURCE")"
#  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
#done
#DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

if [ "$1" = "init" ]
then
    if [ "x$DIR" = "x" ]
    then
        mkdir -p .tf
        search_up
        echo -e "${GREEN}Initialized directory $DIR${NC}"
        exit 0
    else
        (>&2 echo -e "${RED}Already initialized in $DIR${NC}")
        exit 1
    fi
fi

if [ "x$DIR" = "x" ]
then
    (>&2 echo -e "${RED}No initialized directory.${NC}")
    exit 1
else
    echo -e "${GREEN}Root: $DIR${NC}"
fi

WORKSPACE_FILE=$DIR/.tf/.workspace
STACK_FILE=$DIR/.tf/.stack
ACCOUNTS_FILE=$DIR/accounts

## Read accounts
if ! [[ -e $ACCOUNTS_FILE ]]
then
    (>&2 echo -e "${RED}$ACCOUNTS_FILE file missing.${NC}")
    exit 1
fi

declare -A accounts
while IFS=$'=' read -r -a anArray
do
    accounts[${anArray[0]}]=`echo ${anArray[1]} | sed s/[^0-9]//`
done < $ACCOUNTS_FILE

if ! [ -d $DIR/stacks ]
then
    (>&2 echo -e "${RED}No current stack. Create 'stacks' directory and use: $0 stack [stack name].${NC}")
    exit 1
fi

VALID_STACKS=`find $DIR/stacks -maxdepth 1 -mindepth 1 -type d -printf "%f "`

## Select stack
if [ "x$TERRAFORM_STACK" = "x" ] && [ "$1" = "stack" ]
then
    shift
    if contains "$VALID_STACKS" $1
    then
        echo -e "${YELLOW}Switching stack to $1.${NC}"
        export TERRAFORM_STACK=$1
        echo $TERRAFORM_STACK > $STACK_FILE
        echo -e "${GREEN}Stack switched to $TERRAFORM_STACK.${NC}"
        exit 0
    else
        (>&2 echo -e "${RED}stack '$1' is invalid. Usage: $0 stack [$VALID_STACKS].${NC}")
        exit 1
    fi
fi

## Verify stack
if [ "x$TERRAFORM_STACK" != "x" ]
then
    if contains "$VALID_STACKS" $TERRAFORM_STACK
    then
        echo -e "${GREEN}Current stack: $TERRAFORM_STACK (from env)${NC}"
    else
        (>&2 echo -e "${RED}Invalid stack '$TERRAFORM_STACK' (from env). Valid stacks: $VALID_STACKS.${NC}")
        exit 1
    fi
elif [[ -e $STACK_FILE ]]
then
    STACK=`cat $STACK_FILE`
    if contains "$VALID_STACKS" $STACK
    then
        export TERRAFORM_STACK=$STACK
        echo -e "${GREEN}Current stack: $TERRAFORM_STACK${NC}"
    else
        (>&2 echo -e "${RED}No current stack. Use: $0 stack [stack name].${NC}")
    fi
else
    (>&2 echo -e "${RED}No current stack. Usage: $0 stack [$VALID_STACKS].${NC}")
    exit 1
fi

# The stack exists, switch to it
cd $DIR/stacks/$TERRAFORM_STACK
cp $DIR/global.tf global.symlink.tf
cp $DIR/backend.tf backend.symlink.tf

if [ "$1" = "login" ]
then
    if [ "x$TERRAFORM_WORKSPACE" = "x" ]
    then
        TERRAFORM_WORKSPACE=`cat $WORKSPACE_FILE`
    fi
    if [ ${accounts[$TERRAFORM_WORKSPACE]+abc} ]
    then
        echo -e "${GREEN}Current workspace: $TERRAFORM_WORKSPACE${NC}"
    else
        (>&2 echo -e "${RED}No current workspace. Usage: $0 workspace [${!accounts[@]}].${NC}")
        exit 1
    fi
    login $TERRAFORM_WORKSPACE ${accounts[$TERRAFORM_WORKSPACE]}
    exit 0;
fi

## Select (and setup) workspace
if [ "x$TERRAFORM_WORKSPACE" = "x" ] && [ "$1" = "workspace" ]
then
    shift
    if [ "x$1" != "x" ] && [ ${accounts[$1]+abc} ]
    then
        export TERRAFORM_WORKSPACE=$1
        echo $TERRAFORM_WORKSPACE > $WORKSPACE_FILE
        echo -e "${YELLOW}Switching workspace to $TERRAFORM_WORKSPACE${NC}"
        setup_workspace
        echo -e "${GREEN}Workspace switched to $TERRAFORM_WORKSPACE${NC}"
        exit 0
    else
        (>&2 echo -e "${RED}workspace '$1' is invalid. Usage: $0 workspace [${!accounts[@]}].${NC}")
        exit 1
    fi
fi

## Verify workspace
if [ "x$TERRAFORM_WORKSPACE" != "x" ]
then
    if [ ${accounts[$TERRAFORM_WORKSPACE]+abc} ]
    then
        echo -e "${GREEN}Current workspace: $TERRAFORM_WORKSPACE (from env)${NC}"
        setup_workspace
    else
        (>&2 echo -e "${RED}Invalid workspace '$TERRAFORM_WORKSPACE'. Valid workspaces: [${!accounts[@]}].${NC}")
        exit 1
    fi
elif [[ -e $WORKSPACE_FILE ]]
then
    WORKSPACE=`cat $WORKSPACE_FILE`
    if [ ${accounts[$WORKSPACE]+abc} ]
    then
        export TERRAFORM_WORKSPACE=$WORKSPACE
        echo -e "${GREEN}Current workspace: $TERRAFORM_WORKSPACE${NC}"
        setup_workspace
    else
        (>&2 echo -e "${RED}No current workspace. Usage: $0 workspace [${!accounts[@]}].${NC}")
        exit 1
    fi
else
    (>&2 echo -e "${RED}No current workspace. Usage: $0 workspace [${!accounts[@]}].${NC}")
    exit 1
fi

if [ -z $TF_USE_CURRENT_PROFILE ]
then
    export AWS_PROFILE=$TERRAFORM_WORKSPACE
fi

TF_COMMAND=$1
shift

case $TF_COMMAND in
    deps)
        ADD_STATUS=
        if [ "x$1" = "xstatus" ]
        then
            ADD_STATUS=1
        fi
        # check dependencies between modules
        echo -e "digraph {
        compound = \"true\"
        newrank = \"true\"
        node[style=filled]
"
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
                if ! [ -n $ATTRIBUTES ]
                then
                    ATTRIBUTES=${ATTRIBUTES},
                fi
                ATTRIBUTES=${ATTRIBUTES}fillcolor=${COLOR}
            fi
            echo -e \"$stack\"[$ATTRIBUTES]
        done
        grep \\\"terraform_remote_state $DIR/stacks/*/*.tf | sed -e 's/.*\/stacks\///; s/\/.*terraform_remote_state//; s/["{]//g; s/ /" -> "/; s/\s\+$/"/; s/^/"/'

        echo -e "}"
        exit 0;
        ;;
    conf)
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
            "")
                echo "Files on S3:"
                aws s3 ls --recursive s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/
                echo "Sync (dryrun):"
                aws s3 sync --delete --dryrun $DIR/configurationfiles/$PREFIX/$TERRAFORM_WORKSPACE/ s3://$PREFIX-configuration-${accounts[$TERRAFORM_WORKSPACE]}/
                ;;
        esac
        exit $?
        ;;
    chamber)
        export AWS_REGION=eu-west-1
        COMMAND=$1
        case $COMMAND in
            exec|help|history|list)
                chamber "$@"
                exit $?
                ;;
            read|write)
                shift
                SERVICE=$1
                shift
                export CHAMBER_KMS_KEY_ALIAS=alias/$SERVICE-configuration-secrets
                chamber $COMMAND $SERVICE "$@"
                exit $?
                ;;
        esac
        exit 1;
        ;;
    apply)
        export TF_CLI_ARGS="-var-file=../../envvars/${TERRAFORM_WORKSPACE}.tfvars -var-file=../../global.tfvars -input=false -auto-approve=false"
        ;;
    plan|validate|destroy|import|refresh)
        export TF_CLI_ARGS="-var-file=../../envvars/${TERRAFORM_WORKSPACE}.tfvars -var-file=../../global.tfvars -input=false"
        ;;
    get|help|state|graph|fmt|show|taint|untaint|version|output)
        # Should work without any change
        ;;
    re-init)
        init_workspace
        exit $?
        ;;
    *)
        (>&2 echo -e "${RED}Command $TF_COMMAND is unsupported! Use terraform $TF_COMMAND at your own risks...${NC}")
        exit 1;
        ;;
esac

TF_VERSION_FILE=$DIR/stacks/$TERRAFORM_STACK/terraform.version
TF_VERSION="0.11"
if [ -f "$TF_VERSION_FILE" ]; then
    TF_VERSION=`cat $TF_VERSION_FILE`
    if [ $TF_VERSION = "0.12" ]; then
        echo "Working with terraform v0.12 ..."
        terraform-0.12 $TF_COMMAND "$@"
    else
        echo "Version $TF_VERSION is not supported!"
    fi
else
    echo "Working with terraform v0.11 ..."
    terraform-0.11 $TF_COMMAND "$@"
fi

exit $?
