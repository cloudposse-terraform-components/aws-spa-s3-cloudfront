# This mixin requires that a local variable named `github_actions_iam_policy` be defined
# and its value to be a JSON IAM Policy Document defining the permissions for the role.
# It also requires that the `github-oidc-provider` has been previously installed.

variable "github_actions_iam_role_enabled" {
  type        = bool
  description = <<-EOF
  Flag to toggle creation of an IAM Role that GitHub Actions can assume to access AWS resources
  EOF
  default     = false
}

variable "github_actions_allowed_repos" {
  type        = list(string)
  description = <<EOF
  A list of the GitHub repositories that are allowed to assume this role from GitHub Actions. For example,
  ["cloudposse/infra-live"]. Can contain "*" as wildcard.
  If org part of repo name is omitted, "cloudposse" will be assumed.
  EOF
  default     = []
}

variable "github_actions_iam_role_attributes" {
  type        = list(string)
  description = "Additional attributes to add to the role name"
  default     = []
}


locals {
  github_actions_iam_role_enabled = local.enabled && var.github_actions_iam_role_enabled && length(var.github_actions_allowed_repos) > 0
  trusted_github_repos_regexp     = "^(?:(?P<org>[^://]*)\\/)?(?P<repo>[^://]*):?(?P<constraint>.*)?$"
  trusted_github_repos_sub = [
    for repo in var.github_actions_allowed_repos : regex(local.trusted_github_repos_regexp, repo)
  ]
  github_repos_sub = [
    for repo in local.trusted_github_repos_sub : (
      repo["constraint"] == "" ?
      format("repo:%s/%s:*", coalesce(repo["org"], "cloudposse"), repo["repo"]) :
      startswith(repo["constraint"], "ref:") || startswith(repo["constraint"], "environment:") ?
      format("repo:%s/%s:%s", coalesce(repo["org"], "cloudposse"), repo["repo"], repo["constraint"]) :
      format("repo:%s/%s:ref:refs/heads/%s", coalesce(repo["org"], "cloudposse"), repo["repo"], repo["constraint"])
    )
  ]
}

module "gha_role_name" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  enabled    = local.github_actions_iam_role_enabled
  attributes = compact(concat(var.github_actions_iam_role_attributes, ["gha"]))

  context = module.this.context
}

module "github_oidc_provider" {
  count = local.github_actions_iam_role_enabled ? 1 : 0

  source  = "cloudposse/stack-config/yaml//modules/remote-state"
  version = "1.8.0"

  component     = "github-oidc-provider"
  environment   = "gbl"
  privileged    = false
  ignore_errors = true

  defaults = {
    oidc_provider_arn = ""
  }

  context = module.gha_role_name.context
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  count = local.github_actions_iam_role_enabled ? 1 : 0

  statement {
    sid = "OidcProviderAssume"
    actions = [
      "sts:AssumeRoleWithWebIdentity",
      "sts:SetSourceIdentity",
      "sts:TagSession",
    ]

    principals {
      type        = "Federated"
      identifiers = [one(module.github_oidc_provider[*].outputs.oidc_provider_arn)]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_repos_sub
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count              = local.github_actions_iam_role_enabled ? 1 : 0
  name               = module.gha_role_name.id
  assume_role_policy = one(data.aws_iam_policy_document.github_actions_assume_role[*].json)

  inline_policy {
    name   = module.gha_role_name.id
    policy = local.github_actions_iam_policy
  }
}

output "github_actions_iam_role_arn" {
  value       = one(aws_iam_role.github_actions[*].arn)
  description = "ARN of IAM role for GitHub Actions"
}

output "github_actions_iam_role_name" {
  value       = one(aws_iam_role.github_actions[*].name)
  description = "Name of IAM role for GitHub Actions"
}
