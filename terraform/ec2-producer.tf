# =============================================================================
# EC2 producer/consumer host — private subnet, SSM access only
#
# Runs six Python producers/consumers targeting the Edge cluster at
# ~500 KB–1 MB/s combined. No public IP, no inbound security-group rules.
# Access from your Mac: aws ssm start-session --target <instance-id>
# =============================================================================

# --- Latest Amazon Linux 2023 AMI (SSM agent pre-installed) ---

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# --- IAM role that lets SSM manage the instance ---

resource "aws_iam_role" "producer_host" {
  name = "${var.resource_prefix}-producer-host-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "producer_ssm" {
  role       = aws_iam_role.producer_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "producer_host" {
  name = "${var.resource_prefix}-producer-host-profile"
  role = aws_iam_role.producer_host.name
}

# --- Security group: no inbound, HTTPS out for SSM + Python deps ---

resource "aws_security_group" "producer_host" {
  name        = "${var.resource_prefix}-producer-host-sg"
  description = "Producer host - SSM only, no inbound"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSM + pip + Confluent Hub"
  }

  # Kafka external listeners on Edge (SASL_SSL)
  egress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kafka brokers"
  }

  # Schema Registry
  egress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Schema Registry"
  }

  tags = merge(local.tags, { Name = "${var.resource_prefix}-producer-host-sg" })
}

# --- EC2 instance ---

resource "aws_instance" "producer_host" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private.id
  iam_instance_profile   = aws_iam_instance_profile.producer_host.name
  vpc_security_group_ids = [aws_security_group.producer_host.id]

  # No key pair — access via SSM only
  associate_public_ip_address = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3 python3-pip git
    pip3 install confluent-kafka
  EOF

  tags = merge(local.tags, { Name = "${var.resource_prefix}-producer-host" })
}
