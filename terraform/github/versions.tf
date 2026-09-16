terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  backend "local" {}

  required_providers {
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
}

provider "github" {
  owner = "SpencerC"
}
