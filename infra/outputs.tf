output "cloudfront_domain_name" {
  description = "CloudFront hostname the wildcard DNS records point at."
  value       = aws_cloudfront_distribution.previews.domain_name
}

output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.previews.id
}

output "example_preview_url" {
  description = "Replace <rest-of-slug> so the label matches a real preview's slug (the part before .vercel.app)."
  value       = "https://${var.vercel_project_prefix}<rest-of-slug>.previews.${var.domain}"
}
