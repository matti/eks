provider "aws" {
  region                  = "eu-central-1"
  profile                  = "dolan"
}

variable "aws_profile" {
  default     = "dolan"
}

resource "aws_vpc" "default" {
  cidr_block       = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                             = {
    "kubernetes.io/cluster/${terraform.workspace}" = "shared"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "default" {
  count = 3
  vpc_id     = aws_vpc.default.id
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  map_public_ip_on_launch = true
  cidr_block = cidrsubnet(aws_vpc.default.cidr_block, 4, count.index)
  tags                             = {
    "kubernetes.io/cluster/${terraform.workspace}" = "shared"
  }
}

resource "aws_eip" "nlb" {
  count = 3
}

resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id
}

resource "aws_route_table" "default" {
  vpc_id = aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default.id
  }
}

resource "aws_route_table_association" "public" {
  count = "${length(aws_subnet.default.*.id)}"

  route_table_id = aws_route_table.default.id
  subnet_id      = element(aws_subnet.default.*.id, count.index)
}

resource "aws_lb" "default" {
  load_balancer_type = "network"
  enable_cross_zone_load_balancing = true

  subnet_mapping {
    subnet_id     = aws_subnet.default.0.id
    allocation_id = aws_eip.nlb.0.id
  }
  subnet_mapping {
    subnet_id     = aws_subnet.default.1.id
    allocation_id = aws_eip.nlb.1.id
  }
  subnet_mapping {
    subnet_id     = aws_subnet.default.2.id
    allocation_id = aws_eip.nlb.2.id
  }
}

resource "aws_lb_target_group" "http" {
  vpc_id = aws_vpc.default.id
  port     = 80
  protocol = "TCP"
}

resource "aws_lb_target_group" "https" {
  vpc_id = aws_vpc.default.id
  port     = 443
  protocol = "TCP"
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.default.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    target_group_arn = aws_lb_target_group.http.arn
    type             = "forward"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.default.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    target_group_arn = aws_lb_target_group.https.arn
    type             = "forward"
  }
}

data "aws_iam_policy_document" "cluster_assume_role_policy" {
  statement {
    sid = "EKSClusterAssumeRole"

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks" {
  name_prefix = "eks"
  assume_role_policy    = data.aws_iam_policy_document.cluster_assume_role_policy.json
}

resource "aws_eks_cluster" "default" {
  name = terraform.workspace
  role_arn = aws_iam_role.eks.arn
  enabled_cluster_log_types = ["api","audit","authenticator","controllerManager","scheduler"]

  vpc_config {
    subnet_ids = aws_subnet.default.*.id
  }
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks.name
}

data "aws_region" "default" {}

data "aws_ami" "eks_worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.cluster_version}-${var.worker_ami_name_filter}"]
  }

  most_recent = true

  # Owner ID of AWS EKS team
  owners = ["602401143452"]
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster."
  default     = "1.12"
}

variable "worker_ami_name_filter" {
  description = "Additional name filter for AWS EKS worker AMI. Default behaviour will get latest for the cluster_version but could be set to a release from amazon-eks-ami, e.g. \"v20190220\""
  default     = "v*"
}

data "aws_iam_policy_document" "instance-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "management" {
  name_prefix = "management"
  assume_role_policy = "${data.aws_iam_policy_document.instance-assume-role-policy.json}"
}

locals {
  worker_node_policies = [
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
   ]
}

resource "aws_iam_role_policy_attachment" "management_node_policy" {
  count = length(local.worker_node_policies)
  policy_arn = local.worker_node_policies[count.index]
  role       = aws_iam_role.management.name
}

resource "aws_iam_instance_profile" "management" {
  role = aws_iam_role.management.name
}

resource "aws_iam_role_policy" "management" {
  name = "${aws_eks_cluster.default.name}_management"
  role = aws_iam_role.management.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_launch_configuration" "management" {
  image_id             = data.aws_ami.eks_worker.id
  iam_instance_profile = aws_iam_instance_profile.management.name
  instance_type        = "t2.small"
  security_groups = ["${aws_security_group.ssh.id}"]
  # associate_public_ip_address = true
  user_data            = base64encode("/etc/eks/bootstrap.sh '${aws_eks_cluster.default.name}'")
  key_name   = "dolan"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "management" {
  vpc_zone_identifier  = aws_subnet.default.*.id
  min_size             = 1
  max_size             = 3
  launch_configuration = aws_launch_configuration.management.id
  # target_group_arns    = [aws_lb_target_group.http.arn, aws_lb_target_group.https.arn]

/*   health_check_type         = "ELB"
  health_check_grace_period = 600
 */
  termination_policies = [
    "OldestInstance",
  ]

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${terraform.workspace}"
    value               = "true"
    propagate_at_launch = true
  }

/*   tag {
    key                 = "Name"
    value               = "${terraform.workspace}-asg-eks"
    propagate_at_launch = true
  }
 */
  /* tag {
    key                 = "role"
    value               = "eks-worker"
    propagate_at_launch = true
  }
 */

  tag {
    key                 = "kubernetes.io/cluster/${terraform.workspace}"
    value               = "owned"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = ["desired_capacity"]
  }
}

resource "null_resource" "kubeconfig" {

 provisioner "local-exec" {
   environment = {
     KUBECONFIG = pathexpand("~/.kube/${terraform.workspace}")
   }
   command = "while true; do aws eks update-kubeconfig --name ${terraform.workspace} --region ${data.aws_region.default.name} --profile ${var.aws_profile}; sleep 1; done"
 }
}

resource "local_file" "cluster_autoscaler" {
 content  = templatefile("${path.module}/cluster_autoscaler.yml", { aws_region = data.aws_region.default.name, aws_management_autoscaling_group = aws_autoscaling_group.management.name })
 filename = "/tmp/cluster_autoscaler.yml"
}

resource "null_resource" "kubectl_cluster_autoscaler" {

 provisioner "local-exec" {
   environment = {
     KUBECONFIG = pathexpand("~/.kube/${terraform.workspace}")
   }
   command = "kubectl apply -f ${local_file.cluster_autoscaler.filename}"
 }
}

resource "local_file" "aws_auth_configmap" {
 content  = templatefile("${path.module}/aws_auth_configmap.yml", { aws_iam_role_management_arn = aws_iam_role.management.arn })
 filename = "/tmp/aws_auth_configmap.yml"
}

resource "null_resource" "kubectl_aws_auth_configmap" {

 provisioner "local-exec" {
   environment = {
     KUBECONFIG = pathexpand("~/.kube/${terraform.workspace}")
   }
   command = "kubectl apply -f ${local_file.aws_auth_configmap.filename}"
 }
}

resource "aws_security_group" "ssh" {
  description = "cluster management"
  vpc_id      = "${aws_vpc.default.id}"

  ingress {
    cidr_blocks     = ["0.0.0.0/0"]
/*     from_port       = 22
    to_port         = 22
    protocol        = "tcp"
 */
    from_port       = 0
    to_port         = 0
    protocol        = "-1"

  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

}
