# Assessment Responses

---

## Section 1: Code Review (~15 min)

Review the code in `review/pull_request.tf`. A teammate has submitted it as a PR to deploy a new Rails service to EKS. Write your feedback as you would in a real GitHub PR review.

For each issue: **what's wrong**, **why it matters**, and **what you'd suggest instead**.

**Your review:**

<!-- Write your code review here -->
1. The IRSA trust policy has no Condition which means any pod/service in the cluster can assume this role (line 15). <br/>
It matters because the current policy defeats the purpose of having IRSA. It also poses a security threat as  compromised pod would have access to the entire cluster. <br/>
Suggestion: Add condition to narrow the permission scope:
    ```
    Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
            StringEquals = {
            "oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE:sub" = "system:serviceaccounts:services:my-service"
            "oidc.eks.us-east-2.amazonaws.com/id/EXAMPLE:aud" = "sts.amazonaws.com"
            }
        }
    ```
    The the OIDC provider ARN should be build dynamically from the EKS cluster resource instead of hard-coding it. <br/>
    It matters because the hard-coded values tie resource to a particular account which prevents portability and creates tight coupling. <br/>
    Suggestion: define aws_caller_identity declaration and reference it to get aws account id

2. Line #62 is incorrect because kubernetes deployment needs a service account name, not IAM role. <br/>
It matters because pod won't be able to wire IRSA correctly because no kubernetes_service_account resource is defined. It will force the pod run under the default account which will lead to API call failures due to missing permissions. <br/>
Suggestion:  Add `kubernetes_service_account` resource with the role attached, ie 
    ```
    resource "kubernetes_service_account" "app" {
        metadata {
        name      = "my-service"
        namespace = "services"
        annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.service_role.arn
        }
        }
    }
    ```
    and then reference it as service_account_name. 
  
  3. The `service_account_name` should be under spec.template instead of being at the top-level spec. <br/>
  It matters because the service account belongs to the pod template, not the deployment. This will fail the TF validation <br/>
  Suggestion: move service_account_name to be inside template.spec{} block

4. **Critical**: Hard-coded DB credentials in plain text, line #88. <br/>
It matters because it's a major security risk since we're storing credentials in public SC system which could be compromized and used to gain access to the system. It'll also remain in git history. Plus, it makes credential rotation much harder. It's a security violation of PCI, SOC2 and other security standards. <br/>
Suggestion: Store DB credentials externally in AWS SecretsManager to allow other services to access it. Enforce periodic credential rotation. 

5. Redis URL is hard-coded in the code <br/>
It matters because it's an env-specific value which makes the code less portable across dev/staging/prod env <br/>
Suggestion: use ConfigMap with namespace and env-specific values through variables

6. **Critical**: The IAM permissions for service_policy are too broad. <br/>
It matters because the policy permissions are beyond the need of what the pod needs. If the pod is compromized, the attacker gets extremely broad access across SSM, SecretsManager, S3 amd KMS which poses the big security risk. <br/>
Suggestion: scope permissions down to exactly what the service needs. Always follow the least-privilege approach even if it takes multiple iterations of `AccessDenied` errors. Use specific actions, ie `secretsmanager:getSecretValue`, `eks:Decrypt`, `s3:GetObject` with resource as specific as possible, ie `arn:aws:secretsmanager:{aws:region}:{aws:account}:secret:my-app-db-{env}-password-*`

7. Service policy IAM role name is too generic. <br/>
It matters because it does not include app name and env which will make it harder to audit and troubleshoot. <br/>
Suggestion: Establish and follow the naming convention for resources, ie: `{env}-service-role-{app}` to distinguish across multiple accounts

8. The inline IAM service_policy is not reusable, and it clutters the existing code. <br/>
It matters because it's hard to maintain and reuse the same policy if another resource needs the same permission. It also makes it harder to read the code, esp for large permissison sets. <br/>
Suggestion: Build the policy document with required permissions, then attach it to a resource

9. Using `latest` image tag is risky. <br/>
It matters because we introduce image mutation with every image being tagged as `latest` without knowing exactly what image version is running. Using `latest` leaves no audit version trail and makes it hard to rollback. <br/>
Suggestion: Use immutable image tag tied to CI build, ie: SHA-based or timestamp-based tag from CI/CD pipeline

10. Container has no resource limits <br/>
It matters because we want to differentiate configurations between diff environments in terms of resource usage, ie: CPU, memory. It also makes it possible for one bad pod to consume most of the resources making the cluster unstable. <br/>
Suggestion: Define container limits using per-env variables

11. No health/readiness check is defined. <br/>
It matters because without a readiness/health probe, Kubernetes could route traffic to a pod before the container starts, before the app is initialized or established DB connection. <br/> 
Suggestion: Add readiness and liveness probes, ie 
    ```
    readiness_probe {
        http_get { path = "/health", port = 3000 }
        initial_delay_seconds = 15
        period_seconds        = 5
    }
    liveness_probe {
        http_get { path = "/health", port = 3000 }
        initial_delay_seconds = 30
        period_seconds        = 10
    }
    ```

12. No namespace is defined. <br/>
It matters because we should follow the defined naming convention. It also makes querying pods hard, instead of using `kubectl get pods -n services` <br/>
Suggestion: Use `services` namespace to follow the naming convention

13. No security context defined. <br/>
It matters because the container may run with more privileges than it needs, ie: as root which is uncecessary security risk. <br/>
Suggestion: add `run_as_non_root = true` to the security_context on line #81


---

## Section 2: Design Question (~15 min)

Each Rails service gets its own IAM role via IRSA (IAM Roles for Service Accounts), scoped to a service-specific secrets path:

```
arn:aws:ssm:{region}:{account}:parameter/{service-name}/*
```

A developer asks: *"Can we just create one shared IAM role for all services? They all need the same permissions — SSM, Secrets Manager, KMS decrypt, and EventBridge PutEvents. Separate roles are a maintenance burden."*

**Question**: Write your response. Address:
- Why you would or would not adopt a shared role
- If you reject it, propose a **practical alternative** that reduces overhead without removing the security boundary
- Describe a **concrete scenario** where per-service roles prevent a real incident

**Your response:**

<!-- Write your answer here -->
I would not recommend adopting one shared IAM role or all Rails services, even if the permissions might look similar. The main issue is that each service is different and should be able to access its own secrets, KMS key, SSM parameters, etc. Using a shared role would collapse all these boundaries. A single shared IRSA role would mean multiple unrelated workloads all assume the same AWS identity. This is wrong for several reasons:
- it breaks the least privilege access pattern
- it removes service-to-service isolation
- it makes it easier for one compromized pod to access another service resources, ie: secrets
- it makes the audit and CT trails harder to read since multiple services use the same role
- it ties unrelated service permission-wise, and a change will affect all of them.
- Even if all services use SSM, SecretsManager and KMS, each service should have diff scope, ie: <br/>
`secretsmanager:GetSecretValue on arn:aws:secretsmanager:...:secret:/payments/*` <br/>
is not the same as <br/>
`secretsmanager:GetSecretValue on arn:aws:secretsmanager:...:secret:/orders/*` <br/>
What's wrong with this approach: <br/>
The blast radius increases, ie: if one service is compromised, ie: dependency compromise,  leaked pod exec access, the attacker gets the full permissions of a shared role. That may include secrets and config for every other service using that role. <br/>
The permission creep becomes inevitable as shared roles almost always grow over time. <br/>Example: Service A needs one more secret, Service B needs another KMS permission, Service C needs access to a second bus. The shared role accumulates all of it, and eventually every service has everyone's access. <br/>
What I would suggest instead: <br/>
I would keep per-service roles with an agreement that the current approach can feel like maintenance overhead. I would solve this by standardizing the implementation and creating a reusable Terraform module for service roles that takes a small set of input parameters: <br/>
`service name`, `namespace`, `secrets path`, `ssm path`, etc. This module, when invoked, creates an IAM role, with the trust relationship restricted to the exact Kubernetes service account. <br/>
Here's the concrete incident scenario where the `per-service roles` could prevent a real problem: <br/>
Suppose we have two Rails services: public-api and billing-worker. The `public-api` service is internet-facing and it parses user input. The `billing-worker` has access to some internal secrets, invoice encryption, billing events, etc. With the shared role, if a public-api is ever compromized, the attacker can use the pod credentials to read `billing-worker` secrets, decrypt billing-related data via KMS, maybe publish some fake billing events to EventBridge, etc. This turns a compromize of a lower-sensitivity service  into a major security threat. 


---

## Section 3: Service Deployment Rationale (~5 min of your 30)


**Your response for dev:**

# Dev ──────────────────────────────────────────────────────────────────────

# TODO: Write the dev configuration for payment-processor
```
<!-- Write your answer above in HCL -->
module "payment_processor_dev" {
  source = "../modules/service-stack"

  service_name    = "payment-processor"
  vpc_id          = data.terraform_remote_state.network.outputs.vpc_id
  db_subnet_group = data.terraform_remote_state.network.outputs.db_subnet_group
  cluster_name    = data.terraform_remote_state.network.outputs.cluster_name
  namespace       = "services"

  # Database — small, encrypted assuming we have financial records even in dev 
  db_instance_class         = "db.t3.small"
  db_storage_gb             = 20
  db_max_storage_gb         = 100
  db_multi_az               = false
  db_backup_days            = 7
  db_skip_final_snapshot    = true
  db_encryption             = true
  db_performance_insights   = false

  # Cache — lightweight in dev, single node is fine.
  cache_node_type           = "cache.t3.micro"
  cache_cluster_mode        = false
  cache_snapshot_days       = 0

  # App — 1 replica adequate for dev testing
  app_replicas              = 1
  app_cpu_request           = "250m"
  app_memory_request        = "512Mi"
  app_cpu_limit             = "500m"
  app_memory_limit          = "1Gi"

  # Workers — required: payment events arrive asynchronously
  enable_workers            = true
  worker_replicas           = 1
  worker_cpu_request        = "250m"
  worker_memory_request     = "512Mi"
  worker_cpu_limit          = "500m"
  worker_memory_limit       = "1Gi"
}
```


**Your response for prod:**

# Prod ──────────────────────────────────────────────────────────────────────

# TODO: Write the prod configuration for payment-processor
```
<!-- Write your answer above in HCL -->
module "payment_processor_prod" {
  source = "../modules/service-stack"

  service_name    = "payment-processor"
  vpc_id          = data.terraform_remote_state.network.outputs.vpc_id
  db_subnet_group = data.terraform_remote_state.network.outputs.db_subnet_group
  cluster_name    = data.terraform_remote_state.network.outputs.cluster_name
  namespace       = "services"

  # Database — production: multi-AZ, memory-optimized, 30-day backups 
  db_instance_class         = "db.r6g.large"
  db_storage_gb             = 100
  db_max_storage_gb         = 500
  db_multi_az               = true
  db_backup_days            = 30
  db_skip_final_snapshot    = false
  db_encryption             = true
  db_performance_insights   = true

  # Cache — clustered for failover
  cache_node_type           = "cache.r6g.large"
  cache_cluster_mode        = true
  cache_snapshot_days       = 7

  # App — 5 replicas for HA; can absorb 1st/15th traffic spikes 
  app_replicas              = 5
  app_cpu_request           = "500m"
  app_memory_request        = "1Gi"
  app_cpu_limit             = "1000m"
  app_memory_limit          = "2Gi"

  # Background workers — important for async payment ingestion and processing.
  enable_workers            = true
  worker_replicas           = 5
  worker_cpu_request        = "500m"
  worker_memory_request     = "1Gi"
  worker_cpu_limit          = "1000m"
  worker_memory_limit       = "2Gi"
}
```

### Why did you choose these specific values for a payment service?
- Use encryption in both env because we deal with financial data
- Enable workers because the service receives payment events asynchronously
- db.r6g.large for prod because memory optimize instances handle write transactional workloads better than burstable t3
- backup days 30 in prod to comply with audit requirements
- always take the final snapshot in prod to prevent accidential destroy
- use cache cluster mode in prod, ie primary node and a read replica across multiple AZs. We cannot afford Redis failure because that will mean every cache miss which will hit the database affecting its performance, crucial esp on 1st and 15th

<!-- What drove your sizing decisions? How does this service differ from a typical CRUD app? -->
Payment service cannot tolerate duplicate or missing record. It has to enforce idempotency meaning the same payment can never be processed twice. The app should use idempotency keys stored in cache or DB to enforce one-only processing pattern. 
A service must be atomic and transactional: debit one account, credit another and emit event. All must either succeed or fail.
Worker must have redundancy and retry logic built-in in case of a failure. 
A database tables must reflect a transaction state, ie: received -> validated -> reserved -> processed, etc


### What's the most important difference between your dev and prod configs, and why?

<!-- Pick the one that matters most for a financial transaction workload -->
I'd say the "multi AZ deployment" is the most important to ensure fault-tolerance in case of a single AZ issues. The applications need to have retry logic when TCP connection changes

### What's missing that you'd add with more time?
1. Autoscaling policy for app/worker replicas. A Horizontal Pod Autoscaler (or scheduled scaling) would handle the traffic burst without over-provisioning infrastructure
2. Read replicas in each AZ for the database to handle read operations and act as failover nodes. The current module doesn't expose a db_read_replicas variable. 
3. Evaluate Aurora Serverless v2 which handles scaling on demand and removes the need of having provisioned resources when not in use
4. DLQ for workers in case a payment event fails processing. Add alert on DLQ messages
5. General observability, ie: publishing metrics to internal (CloudWatch) and external (Datadog, New Relic, Grafana) system for observability, history trends, alerts and troubleshooting

<!-- We'll use this as an interview talking point -->

---

## AI tools used (optional)
chatGPT for asbtract ideas and a big picture. Claude code for agentic implementation and troubleshooting. I always verify the info AI generates, ask questions and ask for correction if responses seem inacurate.  
<!-- Which tools you used and what you validated/modified. Positive signal, not a penalty. -->
