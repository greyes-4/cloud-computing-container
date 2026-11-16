# Existing AWS network resources
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# Load balancer security group
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "The load balancer: open to the internet on the two listener ports"
  vpc_id      = data.aws_vpc.default.id
}

# Application security group
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "The app instances: reachable only from the load balancer"
  vpc_id      = data.aws_vpc.default.id
}

# Allow public access to ALB listener ports
resource "aws_vpc_security_group_ingress_rule" "alb_from_internet" {
  for_each = local.tiers

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
}

# Allow the ALB to reach application instances
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
}

# Only the ALB can access the application port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
}

# Optional SSH access
resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  count = var.ssh_cidr == "" ? 0 : 1

  security_group_id = aws_security_group.app.id
  cidr_ipv4         = var.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# Allow instances to access the internet
resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
