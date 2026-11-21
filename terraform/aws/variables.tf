variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "zabbix-ha"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.project_name))
    error_message = "project_name must contain lowercase letters, numbers, and hyphens."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "ami_id" {
  type        = string
  description = "Pinned Ubuntu 24.04 LTS AMI ID, valid for the region and instance architecture."
}

variable "manager_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "worker_instance_type" {
  type        = string
  description = "Instance type sized for PostgreSQL, ClickHouse, Keeper, etcd and Zabbix workloads."
}

variable "allowed_web_cidrs" {
  type        = list(string)
  description = "IPv4 ranges permitted to reach web and Zabbix ingress."
  default     = []
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "volume_sizes_gb" {
  type = object({
    postgres   = number
    etcd       = number
    clickhouse = number
    keeper     = number
    proxy      = number
  })
  description = "Sizes in GiB of independent encrypted persistent volumes."
  validation {
    condition     = alltrue([for size in values(var.volume_sizes_gb) : size >= 1])
    error_message = "Every persistent volume must be at least 1 GiB."
  }
}
