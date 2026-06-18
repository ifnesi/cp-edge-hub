variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "availability_zone" {
  description = "Primary AZ — all nodes, EBS volumes, and NLBs live here"
  type        = string
  default     = "eu-west-2a"
}

# EKS requires the cluster's subnets to span at least two AZs. We add a single
# empty private subnet in this second AZ purely to satisfy that control-plane
# requirement — no nodes are scheduled here, so the workload stays single-AZ.
variable "availability_zone_b" {
  description = "Secondary AZ — used only to satisfy the EKS two-AZ requirement"
  type        = string
  default     = "eu-west-2b"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Public subnet — used by NLBs for external broker access
variable "public_subnet_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

# Private subnet — EKS nodes live here
variable "private_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# Secondary private subnet — control-plane ENIs only, no nodes
variable "private_subnet_b_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

# Instance type for Kafka broker nodes (4 vCPU / 16 GB).
# m5.xlarge gives headroom over the 8 GB request for OS + daemonsets.
variable "broker_instance_type" {
  type    = string
  default = "m5.xlarge"
}

# Instance type for KRaft controller + Schema Registry nodes (2 vCPU / 8 GB).
# Both components fit on an m5.large with room for system processes.
variable "controller_instance_type" {
  type    = string
  default = "m5.large"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "cp-edge-hub-poc"
    ManagedBy   = "terraform"
    Environment = "poc"
  }
}
