tflint {
  required_version = ">= 0.60.0"
}

config {
  call_module_type = "local"
  force = false
  disabled_by_default = false
}

plugin "terraform" {
  # Plugin common attributes
  preset = "recommended"
  enabled = true
}

plugin "aws" {
  enabled = true
  version = "0.45.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "google" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

rule "terraform_module_version" {
  enabled = false
}

rule "terraform_unused_declarations" {
  enabled = false
}

rule "terraform_naming_convention" {
  # Enforce snake_case for all blocks
  enabled = true
}
