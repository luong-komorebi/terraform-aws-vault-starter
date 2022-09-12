# Create a backup bucket for Vault
resource "aws_s3_bucket" "vault_backup" {
  bucket = "${var.resource_name_prefix}-vault-snapshots"
  lifecycle {
    ignore_changes = [server_side_encryption_configuration]
  }
}

resource "aws_s3_bucket_acl" "vault_backup_bucket_acl" {
  bucket = aws_s3_bucket.vault_backup.id
  acl    = "private"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "vault_backup" {
  bucket = aws_s3_bucket.vault_backup.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "template_file" "vault_backup_policy_template" {
  template = templatefile("${path.module}/backup_job_iam.json.tpl", {
    s3_bucket = aws_s3_bucket.vault_backup.arn
  })
}

resource "aws_iam_role_policy" "backup_data" {
  name   = "${var.resource_name_prefix}-vault-snapshots"
  role   = var.aws_instance_role_id
  policy = data.template_file.vault_backup_policy_template.rendered
}
