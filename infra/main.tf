provider "aws" {
  region = local.region

  # Make it faster by skipping something
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
}

locals {
  bucket_name = "s3-bucket-${random_pet.this.id}"
  region      = "us-east-1"
}

resource "random_pet" "this" {
  length = 2
}

module "s3_bucket" {
  source = "./srcmod"
  bucket        = local.bucket_name
  force_destroy = true
}


resource "aws_sqs_queue" "this" {  
  name  = "queue-${random_pet.this.id}"
}

# SQS policy created outside of the module
data "aws_iam_policy_document" "sqs_external" {
  statement {
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.this.arn]
  }
}

resource "aws_sqs_queue_policy" "allow_external" {
  queue_url = aws_sqs_queue.this.id
  policy    = data.aws_iam_policy_document.sqs_external.json
}

module "all_notifications" {
  source = "./srcmod/notification"

  bucket = module.s3_bucket.s3_bucket_id

  eventbridge = true

  sqs_notifications = {
    sqs1 = {
      queue_arn     = aws_sqs_queue.this.arn
      events        = ["s3:ObjectCreated:Put"]
      filter_prefix = "pr."      
    }
  }


  # Creation of policy is handled outside of the module
  create_sqs_policy = false
}
