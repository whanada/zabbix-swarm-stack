output "nodes" {
  value = {
    for name, instance in aws_instance.nodes : name => {
      instance_id = instance.id
      private_ip  = instance.private_ip
      public_ip   = instance.public_ip
      role        = local.nodes[name].role
      zone        = instance.availability_zone
    }
  }
}

output "data_volumes" {
  value = {
    for name, volume in aws_ebs_volume.data : name => {
      id      = volume.id
      node    = local.data_disks[name].worker
      service = local.data_disks[name].kind
    }
  }
}

output "ingress_dns_name" {
  value = aws_lb.ingress.dns_name
}

output "ingress_public_ips" {
  description = "Fixed NLB addresses for local hosts files when public DNS is not configured."
  value       = aws_eip.ingress[*].public_ip
}
