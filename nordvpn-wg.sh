#!/usr/bin/env bash
# NordVPN WireGuard configuration generator.
#
# No jq and no NordVPN application required.
#
# Usage:
#   ./nordvpn-wg.sh [-o DIR]
#   ./nordvpn-wg.sh [-o DIR] de
#   ./nordvpn-wg.sh [-o DIR] de berlin
#   ./nordvpn-wg.sh [-o DIR] de750
#   ./nordvpn-wg.sh [-o DIR] de750.nordvpn.com
#   ./nordvpn-wg.sh list de
#
# Without -o, the .conf file is written to the current directory.
#
# Set the token through NORDVPN_TOKEN:
#   NORDVPN_TOKEN='your-token' ./nordvpn-wg.sh de750

set -uo pipefail

TOKEN="${NORDVPN_TOKEN:-}"
OUTDIR=$PWD

API="https://api.nordvpn.com/v1"
WG='filters[servers_technologies][identifier]=wireguard_udp'

# -q ignores ~/.curlrc, which prevents unexpected user-agent or proxy settings.
# -g disables URL globbing so curl accepts brackets in API query parameters.
# -f turns HTTP 4xx/5xx responses into failures.
CURL=(curl -q -gfsS --connect-timeout 20 --max-time 180)

PRIVATE_KEY=""
SERVER_LINE=""
CONFIG_NAME=""
COUNTRY_ID=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

http_get() {
    "${CURL[@]}" "$@"
}

# resolve_country <country-code>
#
# Sets COUNTRY_ID.
resolve_country() {
    local cc body re

    cc=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')

    body=$(http_get "$API/countries") ||
        die "could not query NordVPN's countries endpoint"

    re="\"id\":([0-9]+),\"name\":\"[^\"]*\",\"code\":\"$cc\""

    COUNTRY_ID=""
    if [[ $body =~ $re ]]; then
        COUNTRY_ID=${BASH_REMATCH[1]}
    fi

    [[ -n $COUNTRY_ID ]] || die "unknown country code: $1"
}

# server_lines <URL>
#
# Splits NordVPN's compact JSON array into one relevant line per server.
# The public API currently returns one "station" field per server.
server_lines() {
    local body

    body=$(http_get "$1") || return 1
    sed 's/"station":"[^"]*"/\n&/g' <<< "$body"
}

# string_field <server-line> <field>
string_field() {
    local re

    re="\"$2\":\"([^\"]*)\""
    [[ $1 =~ $re ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

server_load() {
    local re='"load":([0-9]+)'

    [[ $1 =~ $re ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

server_city() {
    local re='"name":"([^"]*)","latitude":'

    [[ $1 =~ $re ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

server_public_key() {
    local re='"name":"public_key","value":"([^"]*)"'

    [[ $1 =~ $re ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

first_server() {
    local line

    while IFS= read -r line; do
        [[ $line == *'"hostname":"'* ]] || continue
        printf '%s' "$line"
        return 0
    done <<< "$1"

    return 1
}

find_hostname() {
    local lines=$1
    local hostname=$2
    local line

    while IFS= read -r line; do
        if [[ $line == *"\"hostname\":\"$hostname\""* ]]; then
            printf '%s' "$line"
            return 0
        fi
    done <<< "$lines"

    return 1
}

# Prints the online server with the lowest reported load.
best_server() {
    local lines=$1
    local line status n
    local best=""
    local best_load=2147483647

    while IFS= read -r line; do
        [[ $line == *'"hostname":"'* ]] || continue

        status=$(string_field "$line" status) || continue
        [[ $status == "online" ]] || continue

        n=$(server_load "$line") || continue

        if (( 10#$n < best_load )); then
            best=$line
            best_load=$((10#$n))
        fi
    done <<< "$lines"

    [[ -n $best ]] || return 1
    printf '%s' "$best"
}

available_cities() {
    local line place

    while IFS= read -r line; do
        place=$(server_city "$line") || continue
        printf '%s\n' "$place"
    done <<< "$1" | LC_ALL=C sort -fu
}

slugify() {
    printf '%s' "$1" |
        tr '[:upper:] ' '[:lower:]-' |
        sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

select_recommended() {
    local lines
    local url="$API/servers/recommendations?$WG&limit=1"

    lines=$(server_lines "$url") ||
        die "could not query NordVPN server recommendations"

    SERVER_LINE=$(first_server "$lines") ||
        die "NordVPN returned no WireGuard recommendation"

    CONFIG_NAME="nordvpn-recommended"
}

select_exact() {
    local host=$1
    local cc=${host:0:2}
    local lines
    local url

    resolve_country "$cc"

    url="$API/servers?$WG&filters[country_id]=$COUNTRY_ID&limit=0"

    lines=$(server_lines "$url") ||
        die "could not query WireGuard servers for $cc"

    SERVER_LINE=$(find_hostname "$lines" "$host.nordvpn.com") ||
        die "no WireGuard server named '$host.nordvpn.com'; try: ${0##*/} list $cc"

    CONFIG_NAME="nordvpn-$host"
}

select_country() {
    local cc=$1
    local wanted_city=${2:-}
    local lines matches slug
    local url

    resolve_country "$cc"

    if [[ -z $wanted_city ]]; then
        url="$API/servers/recommendations?$WG&filters[country_id]=$COUNTRY_ID&limit=1"

        lines=$(server_lines "$url") ||
            die "could not query server recommendations for $cc"

        SERVER_LINE=$(first_server "$lines") ||
            die "no recommended WireGuard server for $cc"

        CONFIG_NAME="nordvpn-$cc"
        return
    fi

    url="$API/servers?$WG&filters[country_id]=$COUNTRY_ID&limit=0"

    lines=$(server_lines "$url") ||
        die "could not query WireGuard servers for $cc"

    # The city object contains:
    #   "name":"Berlin","latitude":...
    #
    # Fixed-string matching prevents city names from being treated as regexes.
    matches=$(grep -iF \
        "\"name\":\"$wanted_city\",\"latitude\":" \
        <<< "$lines")

    if [[ -z $matches ]]; then
        printf 'error: no WireGuard server in %s/%s\n' \
            "$cc" "$wanted_city" >&2
        printf 'available cities:\n' >&2
        available_cities "$lines" | sed 's/^/  /' >&2
        exit 1
    fi

    SERVER_LINE=$(best_server "$matches") ||
        die "no online WireGuard server in $cc/$wanted_city"

    slug=$(slugify "$wanted_city")
    CONFIG_NAME="nordvpn-$cc-${slug:-city}"
}

list_country() {
    local cc=$1
    local lines line host n place
    local url

    resolve_country "$cc"

    url="$API/servers?$WG&filters[country_id]=$COUNTRY_ID&limit=0"

    lines=$(server_lines "$url") ||
        die "could not query WireGuard servers for $cc"

    while IFS= read -r line; do
        [[ $line == *'"hostname":"'* ]] || continue

        host=$(string_field "$line" hostname) || continue
        n=$(server_load "$line") || n="-"
        place=$(server_city "$line") || place="-"

        printf '%-22s %4s  %s\n' "$host" "$n" "$place"
    done <<< "$lines" | LC_ALL=C sort -k2,2n -k1,1
}

fetch_private_key() {
    local body
    local re='"nordlynx_private_key"[[:space:]]*:[[:space:]]*"([^"]+)"'

    [[ -n $TOKEN && $TOKEN != "YOUR_ACCESS_TOKEN" ]] ||
        die "set TOKEN in the script or provide NORDVPN_TOKEN"

    body=$(http_get \
        -u "token:$TOKEN" \
        "$API/users/services/credentials") ||
        die "could not get account credentials; verify your access token"

    [[ $body =~ $re ]] ||
        die "credentials response did not contain nordlynx_private_key"

    PRIVATE_KEY=${BASH_REMATCH[1]}
}

write_config() {
    local host ip public_key conf

    host=$(string_field "$SERVER_LINE" hostname)
    ip=$(string_field "$SERVER_LINE" station)
    public_key=$(server_public_key "$SERVER_LINE")

    [[ -n $host ]] ||
        die "could not parse the server hostname"
    [[ -n $ip ]] ||
        die "could not parse the server endpoint"
    [[ -n $public_key ]] ||
        die "could not parse the server WireGuard public key"

    umask 077

    mkdir -p -- "$OUTDIR" ||
        die "could not create output directory: $OUTDIR"

    conf="$OUTDIR/$CONFIG_NAME.conf"

    cat > "$conf" <<EOF || die "could not write $conf"
# NordVPN — $host
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.5.0.2/32, fd15:53b6:dead::2/64
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $ip:51820
PersistentKeepalive = 25
EOF

    chmod 600 -- "$conf" ||
        die "could not set permissions on $conf"

    printf 'wrote:    %s\n' "$conf"
    printf 'server:   %s\n' "$host"
    printf 'endpoint: %s:51820/udp\n' "$ip"
    printf 'connect:  sudo wg-quick up %q\n' "$conf"
}

usage() {
    cat <<EOF
Usage:
  ${0##*/} [-o DIR]                    recommended WireGuard server
  ${0##*/} [-o DIR] de                 recommended server in Germany
  ${0##*/} [-o DIR] de berlin          lowest-load online server in Berlin
  ${0##*/} [-o DIR] de750              exact server
  ${0##*/} [-o DIR] de750.nordvpn.com  exact server
  ${0##*/} list de                     list German WireGuard servers

Options:
  -o, --output DIR    write the configuration to DIR
                      (default: current working directory)

Environment:
  NORDVPN_TOKEN       NordVPN manual-setup access token
EOF
}

main() {
    local mode cc city
    local args=()

    # Scan all arguments: extract options, keep positionals in order.
    while (( $# > 0 )); do
        case "$1" in
            -o|--output)
                (( $# >= 2 )) ||
                    die "option $1 requires a directory argument"
                OUTDIR=$2
                shift 2
                ;;
            -o=*|--output=*)
                OUTDIR=${1#*=}
                [[ -n $OUTDIR ]] ||
                    die "option ${1%%=*} requires a directory argument"
                shift
                ;;
            -h|--help)
                usage
                return
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    args+=("$1")
                    shift
                done
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Restore the remaining positional parameters. The ${args[@]+...}
    # form stays safe under 'set -u' when the array is empty (bash < 4.4).
    set -- ${args[@]+"${args[@]}"}

    if (( $# == 0 )); then
        select_recommended
        fetch_private_key
        write_config
        return
    fi

    mode=$(lowercase "$1")

    case "$mode" in
        -h|--help)
            usage
            return
            ;;

        list)
            (( $# == 2 )) || {
                usage >&2
                exit 2
            }

            cc=$(lowercase "$2")
            [[ $cc =~ ^[a-z]{2}$ ]] ||
                die "invalid country code: $2"

            list_country "$cc"
            return
            ;;
    esac

    if [[ $mode =~ ^[a-z]{2}[0-9]+(\.nordvpn\.com)?$ ]]; then
        (( $# == 1 )) || {
            usage >&2
            exit 2
        }

        select_exact "${mode%.nordvpn.com}"

    elif [[ $mode =~ ^[a-z]{2}$ ]]; then
        (( $# <= 2 )) || {
            printf 'error: quote city names containing spaces\n' >&2
            usage >&2
            exit 2
        }

        city=${2:-}
        select_country "$mode" "$city"

    else
        usage >&2
        exit 2
    fi

    fetch_private_key
    write_config
}

main "$@"
