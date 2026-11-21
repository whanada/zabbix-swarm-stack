resource "aws_security_group" "ingress" {
  name_prefix = "${var.project_name}-nlb-"
  vpc_id      = aws_vpc.stack.id
  description = "Public ingress from configured client CIDRs."
  dynamic "ingress" {
    for_each = length(var.allowed_web_cidrs) > 0 ? toset([80, 443, 10051]) : toset([])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.allowed_web_cidrs
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "ingress" {
  count  = 3
  domain = "vpc"
  tags   = { Name = "${var.project_name}-ingress-${count.index + 1}" }
}

resource "aws_lb" "ingress" {
  name_prefix                      = "zbx-"
  load_balancer_type               = "network"
  internal                         = false
  security_groups                  = [aws_security_group.ingress.id]
  enable_cross_zone_load_balancing = true
  dynamic "subnet_mapping" {
    for_each = range(3)
    content {
      subnet_id     = aws_subnet.public[subnet_mapping.value].id
      allocation_id = aws_eip.ingress[subnet_mapping.value].id
    }
  }
}

locals {
  ingress_ports = { web = 80, websecure = 443, zabbix = 10051 }
  targets = {
    for target in setproduct(keys(local.ingress_ports), ["manager-1", "manager-2", "manager-3"]) :
    "${target[0]}-${target[1]}" => { listener = target[0], manager = target[1] }
  }
}

resource "aws_lb_target_group" "ingress" {
  for_each    = local.ingress_ports
  name_prefix = "zbx-"
  port        = each.value
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.stack.id
  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group_attachment" "manager" {
  for_each         = local.targets
  target_group_arn = aws_lb_target_group.ingress[each.value.listener].arn
  target_id        = aws_instance.nodes[each.value.manager].id
  port             = local.ingress_ports[each.value.listener]
}

resource "aws_lb_listener" "ingress" {
  for_each          = local.ingress_ports
  load_balancer_arn = aws_lb.ingress.arn
  port              = each.value
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress[each.key].arn
  }
}
