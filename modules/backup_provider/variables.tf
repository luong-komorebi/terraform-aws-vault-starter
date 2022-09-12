variable "resource_name_prefix" {
  type        = string
  description = "Resource name prefix used for tagging and naming AWS resources"
}

variable "aws_instance_role_id" {
  type        = string
  description = "Instance role to run backup job"
}