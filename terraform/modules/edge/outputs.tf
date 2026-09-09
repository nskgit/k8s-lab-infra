output "gateway_hostname" {
  value       = oci_apigateway_gateway.edge.hostname
  description = "The API Gateway's own hostname (the steering policy's primary CNAME target)."
}

output "gateway_id" {
  value = oci_apigateway_gateway.edge.id
}

output "origin_fqdn" {
  value       = "origin.${var.domain}"
  description = "The stable FQDN both the API Gateway backend and the steering policy's secondary answer point at."
}

output "steering_policy_id" {
  value = oci_dns_steering_policy.edge.id
}
