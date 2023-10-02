Inspired by https://stackoverflow.com/a/45968410

# Installing

## Terraform
Install terraform, make sure ``terraform-0.11`` is on the path

## Main script
Copy ``tf.sh somewhere``, ``/usr/local/bin/tf`` for instance.

## Bash prompt
Copy ``tf-prompt.sh`` somewhere, source it from your bash profile. 

The ``tf_prompt`` function returns ``(<workspace>/<stack>)``. Call `\$(tf_prompt)` somewhere in your prompt variables.

## pum-aws.py

This script is used to login with Privileged User Management.

Copy ``pum-aws.py`` in the same location as tf.sh.

Pre-requisites:
* python 3
* run ``pip install -r requirements.txt``

### 

# Directory structure:

````
.tf/                        Internal configuration. Indicates the root directory.
    .workspace              Current workspace
    .stack                  Current stack
envvars/
    <workspace 1.tfvars>    Variables for <workspace 1>
    <workspace 2.tfvars>    Variables for <workspace 2>
    <...>
stacks/
    <stack 1>
        backend.tf          Partial backend configuration, only declar type (S3) and region
    <stack 2>
        backend.tf
    <...>
state-management/           The directory for the backend of your workspaces and stacks
    <...>
accounts                    Mapping between workspace names and AWS accounts
backend.tf                  Global terraform backend file. Will be copied or symlinked in each stack
global.tf                   Global terraform file. Will be copied or symlinked in each stack
global.tfvars               Global variables, shared by all stacks
````

# Workspaces

You can name your workspaces the way you want, but you need to have:
* a mapping in ``accounts``: ``<workspace>=<AWS account>``
* a AWS profile (in .aws/config and .aws/credentials) named ``<workspace>``
* a file in ``envvars`` named ``<workspace>``

# Pre-requisites

You must have a S3 bucket named ``terraform-state-<account id>`` in each account, and your profile must have:
* read access to the state files of the stacks you consume
* write access to the state files of the stacks you modify

You can use the scripts in ``state-management`` to create the buckets and read/write policies.
Policies are not assigned automatically.

``backend.tf`` should contain something like:
````
terraform {
  backend "s3" {
    region = "eu-west-1"
    encrypt = true
  }
}
````

# Starting up

Execute the script from a directory inside a root (i.e. one of the parent directory must contain a ``.tf`` folder).

Select a stack:
    
    tf stack network
    
Select a workspace:

    tf workspace acc
    
Login with PUM:

    tf login

Do some stuff:

    tf plan
    tf apply

``global.tf``, ``global.tfvars`` and ``envvars/<workspace>.tfvars`` are automatically used when running:    
* ``apply`` 
* ``destroy``
* ``import``
* ``plan``
* ``refresh``
* ``validate`` 

``apply`` always use ``-auto-approve=false``. In an automation scenario, use ``./tf.sh apply -auto-approve=true``

# Managing your backend

Command usage `tf.sh backend <subcommand> <args>`

## Initzialization 
How to create the backend:
* run `terraform init && terraform apply` locally
* run `tf.sh backend init -migrate-state`
 * if you don't have the local state anymore you'll have to import the resources manually
 * check [here](https://developer.hashicorp.com/terraform/cli/import) for more information
* any plan applies needs to use the following syntax `tf.sh backend <command>` (e.g. plan/applu/etc..)

## Subsequent modifications
Switching between workspaces:
* run `tf.sh workspace <workspace>`
* run `tf.sh backend init`


# Dependency graph

``tf deps`` will generate a graph in the dot language to show dependencies between stacks.

``tf deps status`` will add color to each node based on the status return by ``plan``:
* green: up-to-date
* yellow: changes pending
* red: error

See examples: [dependency graph 1](deps-status-1.png), [dependency graph 2](deps-status-2.png)

# Using different versions of terraform

The wrapper expects an executable named ``terraform-0.11`` to be on the path.
You can use version 0.12 or 0.14 in this way:
* create a file named ``terraform.version`` on the root of your repo, or in a stack to use that version for a single stack
* file should contain ``0.12`` or ``0.14`` to select the version

# Extra credentials

If you need to pass variables containing credentials, you can add a file named ``terraform.tfvars`` at the root of your repository.
This file should be excluded from source control. It will be loaded during ``plan/apply/validate/destroy/import/refresh`` commands.

# Unsupported terraform functions

    console
    env
    init
    providers
    push
    workspace

# TODO

1. Show current workspace and stack in bash prompt (in progress, see tf-prompt.sh)
1. Bash autocompletion
1. Initialize a project.
1. Use symlinks if supported instead of copying ``global.tf`` as ``global.symlink.tf``
1. ? Find current stack from current directory, to be able to use ``cd stacks/xxx`` instead of ``tf stack xxx``

# Limitations

* the workspace is tied with the AWS account. Can't have multiple workspaces under the same AWS account