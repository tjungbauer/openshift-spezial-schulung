#!/usr/bin/env bash
# End-to-end smoke test against a running shop – locally or through the Route.
#   scripts/smoke.sh http://localhost:8080
#   scripts/smoke.sh https://$(oc get route web -o jsonpath='{.spec.host}')
# Checks: the UI loads, products are listed, an order can be placed, and every
# service reports its version. Exit code = number of failed checks.
# Needs only curl and grep.
set -uo pipefail

URL="${1:?usage: $0 ROUTE_URL   (e.g. http://localhost:8080)}"
URL="${URL%/}"
JAR="$(mktemp)"
trap 'rm -f "${JAR}"' EXIT
FAILS=0

# -k: OpenShift routes often use the cluster's self-signed certificate
http() { curl -sk --max-time 10 -b "${JAR}" -c "${JAR}" "$@"; }

check() {  # check DESCRIPTION CONDITION-RESULT(0/1) DETAIL
  if [[ "$2" == 0 ]]; then
    printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s  (%s)\n' "$1" "$3"
    FAILS=$((FAILS + 1))
  fi
}

echo "Smoke test for ${URL}"

page="$(http "${URL}/")"
grep -q "ACME Shop" <<<"${page}"
check "UI loads" $? "no 'ACME Shop' in the page"

products="$(http "${URL}/api/catalog/products")"
count="$(grep -o '"id":"[^"]*"' <<<"${products}" | wc -l | tr -d ' ')"
[[ "${count}" -gt 0 ]] && ok=0 || ok=1
check "products are listed (${count})" "${ok}" "${products:0:120}"

# first product that is in stock
product="$(grep -o '"id":"[^"]*"[^}]*"stock":[1-9][0-9]*' <<<"${products}" | head -1 | sed -E 's/"id":"([^"]*)".*/\1/')"
[[ -n "${product}" ]] && ok=0 || ok=1
check "a product is in stock (${product:-none})" "${ok}" "all sold out?"

cart="$(http -X PUT "${URL}/api/cart/cart/items/${product}" -H 'Content-Type: application/json' -d '{"quantity":1}')"
grep -q '"count":1' <<<"${cart}"
check "product added to the cart" $? "${cart:0:120}"

order="$(http -X POST "${URL}/api/orders/orders" -H 'Content-Type: application/json' \
  -d "{\"items\":[{\"product_id\":\"${product}\",\"quantity\":1}]}")"
order_id="$(grep -o '"id":"[A-F0-9]*"' <<<"${order}" | head -1 | sed -E 's/"id":"([^"]*)"/\1/')"
[[ -n "${order_id}" ]] && ok=0 || ok=1
check "order placed (${order_id:-none})" "${ok}" "${order:0:160}"

orders="$(http "${URL}/api/orders/orders")"
grep -q "\"${order_id:-none}\"" <<<"${orders}"
check "order appears in the order list" $? "${orders:0:120}"
http -X DELETE "${URL}/api/cart/cart" >/dev/null

for service in web catalog cart orders review; do
  path="/api/${service}/info"
  [[ "${service}" == "web" ]] && path="/info"
  info="$(http "${URL}${path}")"
  version="$(grep -o '"version":"[^"]*"' <<<"${info}" | sed -E 's/"version":"([^"]*)"/\1/')"
  pod="$(grep -o '"pod":"[^"]*"' <<<"${info}" | sed -E 's/"pod":"([^"]*)"/\1/')"
  [[ -n "${version}" ]] && ok=0 || ok=1
  check "${service} reports version ${version:-?} (pod ${pod:-?})" "${ok}" "${info:0:120}"
done

echo
if [[ "${FAILS}" -eq 0 ]]; then echo "All checks passed"; else echo "${FAILS} check(s) failed"; fi
exit "${FAILS}"
