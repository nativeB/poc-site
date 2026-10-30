variable "aws_profile" {
  description = "Local AWS CLI profile to deploy with."
  type        = string
}

variable "aws_region" {
  description = "Default region. ACM and Lambda@Edge always use us-east-1 regardless."
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Domain with a public Route 53 hosted zone, e.g. qhutch.click. Previews are served at *.previews.<domain>."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for var.domain."
  type        = string
}

variable "vercel_project_prefix" {
  description = "Start of the Vercel preview slugs, e.g. \"poc-site-\". Only matching slugs are proxied."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*-$", var.vercel_project_prefix))
    error_message = "Use lowercase letters, digits and hyphens, ending in a hyphen (e.g. \"poc-site-\")."
  }
}

variable "vercel_slug_suffix" {
  description = "End of the Vercel preview slugs: \"-\" plus the team slug, e.g. \"-quincys-projects\". Stops other Vercel accounts' projects that share the prefix from being served on this domain. Empty disables the check."
  type        = string
  default     = ""

  validation {
    condition     = var.vercel_slug_suffix == "" || can(regex("^-[a-z0-9-]*[a-z0-9]$", var.vercel_slug_suffix))
    error_message = "Use \"\" or a hyphen followed by lowercase letters, digits and hyphens (e.g. \"-quincys-projects\")."
  }
}

variable "vercel_bypass_secret" {
  description = "Optional Vercel 'Protection Bypass for Automation' secret. Leave empty if Deployment Protection is off."
  type        = string
  default     = ""
  sensitive   = true
}

variable "lambda_runtime" {
  description = "Lambda@Edge Node.js runtime."
  type        = string
  default     = "nodejs22.x"
}

variable "budget_alert_email" {
  description = "Optional. If set, creates a free AWS budget that emails this address when monthly spend passes budget_limit_usd."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly spend that triggers the budget alert email."
  type        = number
  default     = 1
}
