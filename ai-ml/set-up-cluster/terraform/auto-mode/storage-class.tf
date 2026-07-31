
# EKS Auto Mode does not create a StorageClass for you - one referencing ebs.csi.eks.amazonaws.com
# is required to dynamically provision EBS volumes via Auto Mode's storage capability.
# https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  allowed_topologies {
    match_label_expressions {
      key    = "eks.amazonaws.com/compute-type"
      values = ["auto"]
    }
  }

  depends_on = [module.eks]
}
