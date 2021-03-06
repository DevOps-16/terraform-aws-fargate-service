variable "secret_id" {
  default = "terraform-aws-fargate-service-test"
}

provider "aws" {
  region = "eu-west-1"
}

resource "random_id" "name" {
  byte_length = 4
  prefix      = "fargate-test-"
}

# Create a VPC.
# This could potentially be made into an option for the module,
# but users would have to consider public vs private subnets,
# various other VPC options, and the cost of NAT gateways.

module "vpc" {
  source  = "claranet/vpc-modules/aws//modules/vpc"
  version = "1.1.0"

  cidr_block = "10.0.0.0/16"
  tags = {
    Name = random_id.name.hex
  }
}

module "subnets" {
  source  = "claranet/vpc-modules/aws//modules/public-subnets"
  version = "1.1.0"

  vpc_id                  = module.vpc.vpc_id
  gateway_id              = module.vpc.internet_gateway_id
  map_public_ip_on_launch = true

  cidr_block         = "10.0.0.1/24"
  subnet_count       = 2
  availability_zones = ["eu-west-1a", "eu-west-1b"]

  tags = {
    Name = random_id.name.hex
  }
}

# Create an ALB.
# This could potentially be made into an option for the module,
# but not using shared ALBs is financially wasteful,
# and you usually have to deal with SSL certificates,
# so building it into the module might not be sensible.

resource "aws_security_group" "alb" {
  name   = "${random_id.name.hex}-alb"
  vpc_id = module.vpc.vpc_id
}

resource "aws_security_group_rule" "alb" {
  security_group_id = aws_security_group.alb.id
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_alb" "this" {
  name               = random_id.name.hex
  load_balancer_type = "application"

  subnets  = module.subnets.subnet_ids
  internal = false

  security_groups = [aws_security_group.alb.id]
}

resource "aws_alb_target_group" "this" {
  name                 = random_id.name.hex
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 5
  health_check {
    path = "/"
  }
}

resource "aws_alb_listener" "this" {
  load_balancer_arn = aws_alb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.this.arn
  }
}

locals {
  attached_target_group_arn = aws_alb_listener.this.default_action[0].target_group_arn
}

# Use the module to create a Fargate service and associated resources.

module "fargate_service" {
  source = "../"

  name = random_id.name.hex

  create_ecs_cluster = true

  create_ecs_security_group       = true
  create_alb_security_group_rules = true
  alb_security_group_id           = aws_security_group.alb.id

  create_ecs_task_role = true

  secret_id = var.secret_id

  target_group_arn = local.attached_target_group_arn

  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.subnets.subnet_ids
  assign_public_ip = true
}

# Outputs for testing.

output "cfn_stack_name" {
  value = module.fargate_service.cfn_stack_name
}

output "lambda_function_name" {
  value = module.fargate_service.lambda_function_name
}

output "url" {
  value = "http://${aws_alb.this.dns_name}/"
}
