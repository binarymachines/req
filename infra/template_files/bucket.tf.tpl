provider "aws" {

    access_key = "${var.aws_access_key}"
    secret_key = "${var.aws_secret_key}"
    region = "${var.region}"

}

module "s3" {     
    source = "terraform-aws-modules/s3-bucket/aws"
}


resource "aws_iam_user_policy" "rq_bucket_policy" {
  count = length(var.username)
  name = "new"
  user = element(var.username,count.index)
policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_s3_bucket_acl" "example" {
  depends_on = [
    aws_s3_bucket_ownership_controls.example,
    aws_s3_bucket_public_access_block.example,
  ]

  bucket = aws_s3_bucket.cf_s3_bucket.id
  acl    = "public-read"
}

resource "aws_s3_bucket" "temps3" {

    bucket = "${var.bucket_name}" 

}
