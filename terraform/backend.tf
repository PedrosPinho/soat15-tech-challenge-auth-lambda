# Mesmo bucket/tabela de estado dos demais repositórios, key própria deste repo.
terraform {
  backend "s3" {
    bucket         = "soat15-tc-tfstate-442534931336"
    key            = "auth-lambda/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "soat15-tc-tfstate-lock"
    encrypt        = true
  }
}
