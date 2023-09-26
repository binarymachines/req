#!/bin/bash


pushd ./infra
terraform init
terraform apply
terraform output -json > ../data/infra_setup.json
popd
