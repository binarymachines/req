###
### Makefile for Terraform infrastructure targets
###

tf-vars:

	warp --j2 --template-file=template_files/bucket.tf.tpl --params=bucket_name:rearc_bucket \
	> bucket.tf

	warp --j2 --template-file=template_files/variables.tf.tpl --params=aws_access_key:foo,aws_secret_key:bar \
	> variables.tf