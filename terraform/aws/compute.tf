data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${var.project_name}-node-"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${var.project_name}-node-"
  role        = aws_iam_role.node.name
}

resource "aws_instance" "nodes" {
  for_each                    = local.nodes
  ami                         = var.ami_id
  instance_type               = each.value.role == "manager" ? var.manager_instance_type : var.worker_instance_type
  subnet_id                   = each.value.role == "manager" ? aws_subnet.public[each.value.index].id : aws_subnet.private[each.value.index].id
  associate_public_ip_address = each.value.role == "manager"
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_gb
  }
  tags = {
    Name      = "${var.project_name}-${each.key}"
    SwarmRole = each.value.role
    NodeIndex = tostring(each.value.index + 1)
  }
}

locals {
  data_disks = merge([
    for n in range(3) : {
      for service in concat(["postgres", "etcd", "clickhouse", "keeper"], n == 2 ? ["proxy"] : []) :
      "worker-${n + 1}-${service}" => {
        worker = "worker-${n + 1}"
        index  = n
        kind   = service
        size   = var.volume_sizes_gb[service]
        device = { postgres = "/dev/sdf", etcd = "/dev/sdg", clickhouse = "/dev/sdh", keeper = "/dev/sdi", proxy = "/dev/sdj" }[service]
      }
    }
  ]...)
}

resource "aws_ebs_volume" "data" {
  for_each          = local.data_disks
  availability_zone = local.zones[each.value.index]
  size              = each.value.size
  type              = "gp3"
  encrypted         = true
  tags = {
    Name        = "${var.project_name}-${each.key}"
    SwarmNode   = each.value.worker
    DataService = each.value.kind
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  for_each    = local.data_disks
  device_name = each.value.device
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.nodes[each.value.worker].id
}
