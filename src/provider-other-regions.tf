provider "aws" {
  region = local.failover_region # if var.failover_s3_region is not set, this will fall back on var.region

  alias = "failover"
}

# For cloudfront, the acm has to be created in us-east-1 or it will not work
provider "aws" {
  region = "us-east-1"

  alias = "us-east-1"
}
