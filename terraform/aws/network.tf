data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  zones = slice(data.aws_availability_zones.available.names, 0, 3)
  nodes = merge(
    { for n in range(3) : "manager-${n + 1}" => { role = "manager", index = n } },
    { for n in range(3) : "worker-${n + 1}" => { role = "worker", index = n } }
  )
}

resource "aws_vpc" "stack" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "stack" {
  vpc_id = aws_vpc.stack.id
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.stack.id
  availability_zone       = local.zones[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count                   = 3
  vpc_id                  = aws_vpc.stack.id
  availability_zone       = local.zones[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index + 3)
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-private-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.stack.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.stack.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = 1
  domain = "vpc"
}

resource "aws_nat_gateway" "stack" {
  count         = 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.stack]
}

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.stack.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.stack[0].id
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_security_group" "nodes" {
  name_prefix = "${var.project_name}-nodes-"
  vpc_id      = aws_vpc.stack.id
  description = "Swarm node traffic; restrict external access to approved ingress ranges."
  ingress {
    description = "Inter-node traffic"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }
  dynamic "ingress" {
    for_each = toset([80, 443, 10051])
    content {
      description     = "Traffic from the public load balancer"
      protocol        = "tcp"
      from_port       = ingress.value
      to_port         = ingress.value
      security_groups = [aws_security_group.ingress.id]
    }
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
