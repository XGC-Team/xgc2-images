#!/usr/bin/env bash
set -euo pipefail
dpkg-query -W -f='${Version}\n' nlohmann-json3-dev
probe="$(mktemp)"
trap 'rm -f "$probe"' EXIT
c++ -std=c++20 -x c++ - -o "$probe" <<'CPP'
#include <nlohmann/json.hpp>
#include <cstdint>
static_assert(NLOHMANN_JSON_VERSION_MAJOR >= 3);
int main() {
  using Json = nlohmann::json;
  const auto value = Json::parse("{\"n\":18446744073709551615}");
  if (!value["n"].is_number_unsigned() || value["n"].get<std::uint64_t>() != UINT64_MAX) return 1;
  return Json::parse("{/*comment*/}", nullptr, false).is_discarded() ? 0 : 2;
}
CPP
"$probe"
