#!/usr/bin/env bash
RED='\033[0;31m'
NC='\033[0m'

OLDIFS="$IFS"
IFS=$'\n'

# Check command existence before using it
if ! command -v trivy &> /dev/null; then
  echo "trivy not found, please install it"
  exit
fi
if ! command -v kubectl &> /dev/null; then
  echo "kubectl not found, please install it"
  exit
fi

# CVE-2021-44228
echo "Scanning $1..."

imgs=`kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{" "}' | tr " " "\n" | sort -u`
for img in ${imgs}; do
  echo "scanning ${img}"
  result=`trivy image -f table --severity CRITICAL ${img}`
  if echo ${result} | grep "VULNERABILITY ID" ; then
    echo -e "${RED}${img} is vulnerable, please patch!${NC}"
  fi
done

IFS="$OLDIFS"