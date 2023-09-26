variable "bucket_name" {}

variable "acl_value" {

    default = "private"

}

variable "aws_access_key" {

default = "{{ aws_access_key }}"

}

variable "aws_secret_key" {

default = "{{ aws_secret_key }}"

 }

variable "region" {

    default = "region"

}
