# jq helpers for pod's numbers. Loaded with: jq -L "$SCRIPTS" 'include "pod"; ...'
#
# Pod scales amounts and prices by 10^18 and sends them as 0x hex (unsigned) or as decimal strings
# (signed). A 10^18-scaled amount does not fit a double exactly, so the conversion here is done on
# digit strings, never with floating point: 0x82ff658cf0b3f0000 -> "151.03", exactly.

# Little-endian base-10 digits, normalised so each is 0-9.
def _carry:
  {d: ., i: 0}
  | until(.i >= (.d | length);
      if .d[.i] >= 10
      then .d[.i + 1] = ((.d[.i + 1] // 0) + ((.d[.i] / 10) | floor)) | .d[.i] = (.d[.i] % 10)
      else . end
      | .i += 1)
  | .d;

def _hex_to_dec:
  ltrimstr("0x") | ltrimstr("0X") | ascii_downcase | explode
  | map(if . >= 97 then . - 87 else . - 48 end)
  | reduce .[] as $h ([0]; (map(. * 16) | .[0] += $h) | _carry)
  | reverse | map(tostring) | join("")
  | sub("^0+(?=.)"; "");

# Any pod integer (hex string, decimal string or JSON number) as a decimal integer string.
def int_str:
  if . == null then null
  elif type == "number" then tostring
  elif test("^-?0[xX]") then (if startswith("-") then "-" + (.[1:] | _hex_to_dec) else _hex_to_dec end)
  else . end;

# A decimal integer string divided by 10^n, as an exact decimal string without trailing zeros.
def scaled(n):
  int_str
  | if . == null then null else
      (startswith("-")) as $neg
      | ltrimstr("-") as $d
      | ((n + 1 - ($d | length)) as $k | (if $k > 0 then "0" * $k else "" end) + $d) as $p
      | ($p | length) as $l
      | ($p[0:$l - n] | sub("^0+(?=.)"; "")) as $int
      | ($p[$l - n:] | sub("0+$"; "")) as $frac
      | ($int + (if $frac == "" then "" else "." + $frac end)) as $v
      | (if $neg and $v != "0" then "-" + $v else $v end)
    end;

# A 10^18-scaled pod amount or price as a plain decimal string.
def amount: scaled(18);

# A price that pod sends as 0 when there is none (e.g. no liquidation price): null instead of "0".
def price_or_null: if . == null then null else (amount | if . == "0" then null else . end) end;

def neg: if startswith("-") then .[1:] elif . == "0" then . else "-" + . end;
def abs_str: ltrimstr("-");

# Microseconds (string or number) as an ISO-8601 UTC time. Pod's "never" (2^64 - 1) becomes null.
def us_time:
  if . == null then null else
    int_str | if (length > 17) then null else ((tonumber / 1000000) | floor | todate) end
  end;

# A float as a fixed-point decimal string with up to n decimals, trailing zeros dropped. For computed
# numbers. A double holds about 15 significant digits, so large values get fewer decimals; this also
# keeps the scaled integer below 10^16, where jq would start printing it as 1e+17.
def fixed(n):
  if . == null then null else
    (if . == 0 then 0 else (fabs | log10 | floor) + 1 end) as $digits
    | ([n, ([15 - $digits, 0] | max)] | min) as $k
    | (. * pow(10; $k)) | round | tostring | scaled($k)
  end;

# Market id -> "NVDA perp" / "NVDAx spot", from the /clob/markets list passed as $markets.
def market_map: map({key: .id, value: (.base_token_symbol + " " + .market_type)}) | from_entries;
