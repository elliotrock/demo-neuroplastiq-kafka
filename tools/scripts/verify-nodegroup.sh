STACK=eksctl-neuro-dev-nodegroup-ng-spot
REGION=ap-southeast-2

# Get the role name created by the nodegroup stack
ROLE_NAME=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query "StackResources[?LogicalResourceId=='NodeInstanceRole'].PhysicalResourceId" \
  --output text)

# List attached policies on that role
aws iam list-attached-role-policies --role-name "$ROLE_NAME"