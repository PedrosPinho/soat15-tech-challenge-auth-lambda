data "terraform_remote_state" "db_infra" {
  backend = "s3"

  config = {
    bucket = "soat15-tc-tfstate-442534931336"
    key    = "db-infra/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "k8s_infra" {
  backend = "s3"

  config = {
    bucket = "soat15-tc-tfstate-442534931336"
    key    = "k8s-infra/terraform.tfstate"
    region = "us-east-1"
  }
}
