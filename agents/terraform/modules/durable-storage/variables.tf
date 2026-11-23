variable "bucket_name" {
  description = "Bucket name. Globally unique; the root modules derive it from the cluster name and the account ID."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for encryption at rest. Null uses SSE-S3. When set, an agent role also needs kms:Decrypt and kms:GenerateDataKey on it, which ../agent-identity adds when you pass the same ARN as checkpoint_kms_key_arn."
  type        = string
  default     = null
}

variable "organization_id" {
  description = "AWS Organizations ID. When set, the bucket policy denies every principal outside the organization. Null narrows that to this account alone, which is stricter and correct for a single-account platform."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "How long a superseded checkpoint version is kept. This is the recovery window for an agent that wrote a bad checkpoint."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
}

variable "current_version_expiration_days" {
  description = "Expire current objects after this many days. Null keeps them indefinitely, which is the right default for a bucket that also holds the record of what an agent did. Set it where the checkpoints are purely operational."
  type        = number
  default     = null
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "Delete every checkpoint object and version with the bucket when it is deleted -- by terraform destroy, or by an apply that renames it. Off by default: the bucket is agents' durable state. Set true only on a disposable stack, and terraform destroy needs no separate bucket cleanup (scripts/teardown.sh step 9)."
  type        = bool
  default     = false
}
