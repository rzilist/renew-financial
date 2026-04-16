# =============================================================================
# Section 1: Code Review
# =============================================================================
#
# A teammate has submitted this Terraform code as part of a PR to deploy a new
# Rails service called "my-service" to the EKS cluster. The service needs:
# - An IAM role for pod-level AWS access (IRSA)
# - A Kubernetes deployment running the Rails app
#
# Review this code and provide feedback as you would in a real
# GitHub PR review. For each issue: what's wrong, why it matters, and what
# you'd suggest instead.
# =============================================================================

resource "aws_iam_role" "service_role" {
  name = "eks-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::123456789012:oidcprovider/oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
      }
    ]
  })
}

resource "aws_iam_role_policy" "service_policy" {
  name = "service-access"
  role = aws_iam_role.service_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:*", "secretsmanager:*", "kms:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      }
    ]
  })
}

resource "kubernetes_deployment" "app" {
  metadata {
    name      = "my-service"
    namespace = "default"
  }

  spec {
    replicas = 3

    service_account_name = aws_iam_role.service_role.name

    selector {
      match_labels = {
        app = "my-service"
      }
    }

    template {
      metadata {
        labels = {
          app = "my-service"
        }
      }

      spec {
        container {
          name  = "app"
          image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/myservice:latest"

          port {
            container_port = 3000
          }

          env {
            name  = "DATABASE_URL"
            value = "postgresql://admin:password123@mydb.clusterxyz.us-east-2.rds.amazonaws.com:5432/myservice"
          }

          env {
            name  = "REDIS_URL"
            value = "redis://myredis.abc123.ng.0001.use2.cache.amazonaws.com:6379"
          }
        }
      }
    }
  }
}