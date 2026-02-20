# ============================================================
# iam.tf — IAM roles and instance profiles
#
# AWS Academy Learner Lab Version
# Instead of creating new roles (which is blocked by Academy policy),
# this file fetches the pre-existing LabRole and LabInstanceProfile
# provided to all Learner Lab accounts.
# ============================================================

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

data "aws_iam_instance_profile" "lab_profile" {
  name = "LabInstanceProfile"
}
