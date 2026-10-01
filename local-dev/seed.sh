#!/usr/bin/env bash
# One-off setup after loading content into Snowstorm (run with the stack started):
#   - grants AUTHOR on MAIN to the ihtsdo-sca-author group (Authoring Services copies
#     the branch's AUTHOR/ADMIN groups onto new projects to decide who can see them)
#   - sets the MAIN branch module, namespace, language refset and validation rule groups
#   - links the loaded release into the Classification Service store and sets it as
#     MAIN's previousPackage (the release that classification builds on)
#   - creates a demo project in Authoring Services
# Safe to re-run. Calls go through the gateway as the local "admin" user.
#
# Defaults suit the Australian Edition loaded into MAIN; override with e.g.
#   MODULE_ID=731000124108 NAMESPACE=1000124 LANGUAGE_REFSET=900000000000509007 DIALECT=en-us \
#     ASSERTION_GROUPS=common-authoring,us-authoring ./local-dev/seed.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

: "${MODULE_ID:=32506021000036107}"
: "${NAMESPACE:=1000036}"
: "${LANGUAGE_REFSET:=32570271000036106}"
: "${DIALECT:=en-au}"
: "${ASSERTION_GROUPS:=common-authoring,au-authoring}"
: "${CODE_SYSTEM:=SNOMEDCT}"
: "${PROJECT_KEY:=AUDEMO}"
: "${PROJECT_NAME:=AU Demo Project}"

G="http://localhost:$GATEWAY_PORT"
ADMIN=(-H 'Cookie: local-ims=admin' -H 'Content-Type: application/json')

# curl that prints the response body if the request fails
call() {
  local out status
  out=$(curl -s -w '\n%{http_code}' "$@")
  status=${out##*$'\n'}
  if [ "$status" -ge 400 ]; then
    echo "  failed ($status): ${out%$'\n'*}" >&2
    return 1
  fi
}

echo 'Granting AUTHOR on MAIN to ihtsdo-sca-author'
call -X PUT "${ADMIN[@]}" "$G/snowstorm/snomed-ct/admin/permissions/MAIN/role/AUTHOR" \
  -d '{"userGroups":["ihtsdo-sca-author"]}'

echo "Setting MAIN defaultModuleId=$MODULE_ID defaultNamespace=$NAMESPACE language refset=$LANGUAGE_REFSET ($DIALECT)"
call -X PUT "${ADMIN[@]}" "$G/snowstorm/snomed-ct/branches/MAIN/metadata-upsert" \
  -d "{\"defaultModuleId\":\"$MODULE_ID\",\"defaultNamespace\":\"$NAMESPACE\",\"assertionGroupNames\":\"$ASSERTION_GROUPS\",
       \"requiredLanguageRefsets\":[{\"en\":\"$LANGUAGE_REFSET\",\"default\":\"true\",\"dialectName\":\"$DIALECT\"}]}"

PREVIOUS_PACKAGE=$(basename "$RF2_RELEASE_ZIP")
if [ -f "$RF2_RELEASE_ZIP" ]; then
  echo "Linking $PREVIOUS_PACKAGE into the Classification Service release store"
  mkdir -p "$LOCAL_DEV/data/classification-service/releases"
  ln -sf "$RF2_RELEASE_ZIP" "$LOCAL_DEV/data/classification-service/releases/$PREVIOUS_PACKAGE"
  call -X PUT "${ADMIN[@]}" "$G/snowstorm/snomed-ct/branches/MAIN/metadata-upsert" \
    -d "{\"previousPackage\":\"$PREVIOUS_PACKAGE\"}"
else
  echo "RF2_RELEASE_ZIP not found ($RF2_RELEASE_ZIP) - skipping classification setup" >&2
fi

if curl -sf -o /dev/null "${ADMIN[@]}" "$G/authoring-services/projects/$PROJECT_KEY"; then
  echo "Project $PROJECT_KEY already exists"
else
  echo "Creating project $PROJECT_KEY on $CODE_SYSTEM"
  call -X POST "${ADMIN[@]}" "$G/authoring-services/admin/projects?useNew=true" \
    -d "{\"codeSystemShortName\":\"$CODE_SYSTEM\",\"key\":\"$PROJECT_KEY\",\"name\":\"$PROJECT_NAME\",\"lead\":\"admin\",\"description\":\"Local demo project\"}"
fi

echo 'Done. Log in at http://localhost:'"$GATEWAY_PORT"' and open the project from the Projects page.'
