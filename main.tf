terraform {
  required_version = ">= 0.11.11"
}

resource "vault_auth_backend" "k8s" {
  type = "kubernetes"

  #path = "${data.terraform_remote_state.k8s_cluster.vault_user}-${data.terraform_remote_state.k8s_cluster.environment}"
  path        = "${data.terraform_remote_state.k8s_cluster.outputs.vault_user}-rancher"
  description = "Vault Auth backend for Kubernetes"
}

provider "vault" {
  address = data.terraform_remote_state.k8s_cluster.outputs.vault_addr
}

data "terraform_remote_state" "userdata_server" {
  backend = "atlas"
  config = {
    name = "${var.tfe_organization}/${var.k8s_cluster_workspace}"
  }
}

provider "kubernetes" {
  host = data.terraform_remote_state.k8s_cluster.outputs.k8s_endpoint
  client_certificate = base64decode(
    data.terraform_remote_state.k8s_cluster.outputs.k8s_master_auth_client_certificate,
  )
  client_key = base64decode(
    data.terraform_remote_state.k8s_cluster.outputs.k8s_master_auth_client_key,
  )
  cluster_ca_certificate = base64decode(
    data.terraform_remote_state.k8s_cluster.outputs.k8s_master_auth_cluster_ca_certificate,
  )
}

resource "kubernetes_service_account" "vault_reviewer" {
  metadata {
    name = "vault-reviewer"
  }
}

data "kubernetes_secret" "vault_reviewer_token" {
  metadata {
    name = kubernetes_service_account.vault_reviewer.default_secret_name
  }
}

resource "null_resource" "write_token" {
  provisioner "local-exec" {
    command = "echo ${data.kubernetes_secret.vault_reviewer_token.data.token} > vault-reviewer-token"
  }
}

data "null_data_source" "read_token" {
  inputs = {
    token = chomp(file("vault-reviewer-token"))
  }
  depends_on = [null_resource.write_token]
}

# Use the vault_kubernetes_auth_backend_config resource
# instead of the a curl command in local-exec
resource "vault_kubernetes_auth_backend_config" "auth_config" {
  backend         = vault_auth_backend.k8s.path
  kubernetes_host = "https://${data.terraform_remote_state.k8s_cluster.outputs.k8s_endpoint}:443"
  kubernetes_ca_cert = chomp(
    base64decode(
      data.terraform_remote_state.k8s_cluster.outputs.k8s_master_auth_cluster_ca_certificate,
    ),
  )
  token_reviewer_jwt = data.null_data_source.read_token.outputs["token"]
}

# Use vault_kubernetes_auth_backend_role instead of
# vault_generic_secret
resource "vault_kubernetes_auth_backend_role" "role" {
  backend                          = vault_auth_backend.k8s.path
  role_name                        = "demo"
  bound_service_account_names      = ["cats-and-dogs"]
  bound_service_account_namespaces = ["default", "cats-and-dogs"]
  # TF-UPGRADE-TODO: In Terraform v0.10 and earlier, it was sometimes necessary to
  # force an interpolation expression to be interpreted as a list by wrapping it
  # in an extra set of list brackets. That form was supported for compatibility in
  # v0.11, but is no longer supported in Terraform v0.12.
  #
  # If the expression in the following list itself returns a list, remove the
  # brackets to avoid interpretation as a list of lists. If the expression
  # returns a single list item then leave it as-is and remove this TODO comment.
  policies = [data.terraform_remote_state.k8s_cluster.outputs.vault_user]
  ttl      = 7200
}

