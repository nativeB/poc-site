terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = { Project = "vercel-preview-proxy" }
  }
}

# CloudFront only accepts ACM certs and Lambda@Edge functions from us-east-1.
provider "aws" {
  alias   = "us_east_1"
  profile = var.aws_profile
  region  = "us-east-1"

  default_tags {
    tags = { Project = "vercel-preview-proxy" }
  }
}

locals {
  name          = "vercel-preview-proxy"
  wildcard_host = "*.previews.${var.domain}"
  lambda_src    = "${path.module}/../lambda"
}

# ---------------------------------------------------------------------------
# TLS certificate for *.previews.<domain>
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "previews" {
  provider          = aws.us_east_1
  domain_name       = local.wildcard_host
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.previews.domain_validation_options : o.domain_name => o
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "previews" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.previews.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Lambda@Edge functions
# Lambda@Edge has no environment variables, so config is baked into the zip
# as config.mjs.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "edge" {
  name = "${local.name}-edge"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"] }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "edge_logs" {
  role       = aws_iam_role.edge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "origin_request" {
  type        = "zip"
  output_path = "${path.module}/.build/origin-request.zip"

  source {
    filename = "index.mjs"
    content  = file("${local.lambda_src}/origin-request/index.mjs")
  }
  source {
    filename = "proxy.mjs"
    content  = file("${local.lambda_src}/origin-request/proxy.mjs")
  }
  source {
    filename = "config.mjs"
    content = "export default ${jsonencode({
      domain       = var.domain
      prefix       = var.vercel_project_prefix
      suffix       = var.vercel_slug_suffix
      bypassSecret = var.vercel_bypass_secret
    })};\n"
  }
}

data "archive_file" "origin_response" {
  type        = "zip"
  output_path = "${path.module}/.build/origin-response.zip"

  source {
    filename = "index.mjs"
    content  = file("${local.lambda_src}/origin-response/index.mjs")
  }
  source {
    filename = "rewrite.mjs"
    content  = file("${local.lambda_src}/origin-response/rewrite.mjs")
  }
  source {
    filename = "config.mjs"
    content = "export default ${jsonencode({
      domain = var.domain
      prefix = var.vercel_project_prefix
      suffix = var.vercel_slug_suffix
    })};\n"
  }
}

resource "aws_lambda_function" "origin_request" {
  provider         = aws.us_east_1
  function_name    = "${local.name}-origin-request"
  role             = aws_iam_role.edge.arn
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  filename         = data.archive_file.origin_request.output_path
  source_code_hash = data.archive_file.origin_request.output_base64sha256
  memory_size      = 128
  timeout          = 5
  publish          = true # Lambda@Edge needs a numbered version
}

resource "aws_lambda_function" "origin_response" {
  provider         = aws.us_east_1
  function_name    = "${local.name}-origin-response"
  role             = aws_iam_role.edge.arn
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  filename         = data.archive_file.origin_response.output_path
  source_code_hash = data.archive_file.origin_response.output_base64sha256
  memory_size      = 128
  timeout          = 5
  publish          = true
}

# ---------------------------------------------------------------------------
# CloudFront
# ---------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# AllViewer (not AllViewerExceptHostHeader): the origin-request function needs
# the viewer's Host to know which preview was asked for. Without it, Lambda
# only sees the placeholder origin host. The function then replaces Host with
# <slug>.vercel.app before the request leaves CloudFront.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "previews" {
  enabled         = true
  comment         = "Vercel previews at ${local.wildcard_host}"
  aliases         = [local.wildcard_host]
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  is_ipv6_enabled = true

  # Placeholder; the origin-request function swaps in <slug>.vercel.app.
  origin {
    origin_id   = "vercel"
    domain_name = "vercel.app"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "vercel"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = false

    lambda_function_association {
      event_type = "origin-request"
      lambda_arn = aws_lambda_function.origin_request.qualified_arn
      # The function doesn't read the body, and CloudFront forwards it either
      # way. Leaving this off avoids the 1 MB body limit for Lambda.
      include_body = false
    }

    lambda_function_association {
      event_type = "origin-response"
      lambda_arn = aws_lambda_function.origin_response.qualified_arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.previews.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# ---------------------------------------------------------------------------
# DNS: *.previews.<domain> -> CloudFront
# ---------------------------------------------------------------------------

resource "aws_route53_record" "previews" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.hosted_zone_id
  name    = local.wildcard_host
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.previews.domain_name
    zone_id                = aws_cloudfront_distribution.previews.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# Optional spend alert (the first two AWS budgets are free)
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "alert" {
  count        = var.budget_alert_email == "" ? 0 : 1
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
