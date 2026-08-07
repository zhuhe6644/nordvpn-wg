# nordvpn-wg

Generate NordVPN WireGuard configurations from the command line.

## Features

- Recommended server, anywhere or per country
- Lowest-load online server in a specific city (e.g. Berlin)
- Exact server selection (`de750` or `de750.nordvpn.com`)
- Server listing per country with load and city
- Fetches your private key from the NordVPN API with a manual-setup token
- Writes a ready-to-use `wg-quick` config with `chmod 600` (private key is secret)

## Requirements

- `bash`, `curl`, and standard tools (`sed`, `grep`, `sort`, ...)
- A NordVPN **access token**

### Getting an access token

1. Log in to your NordVPN account and open **Manual setup**.
2. Generate / copy an access token.
3. Export it for the shell session:

   ```bash
   export NORDVPN_TOKEN='your-token'
   ```

The token is only ever sent to `https://api.nordvpn.com` over HTTPS.

## Usage

```bash
./nordvpn-wg.sh                     # recommended server        -> ./nordvpn-recommended.conf
./nordvpn-wg.sh de                  # recommended server in DE  -> ./nordvpn-de.conf
./nordvpn-wg.sh de berlin           # lowest-load server there  -> ./nordvpn-de-berlin.conf
./nordvpn-wg.sh de750               # exact server              -> ./nordvpn-de750.conf
./nordvpn-wg.sh de750.nordvpn.com   # exact server (full host)  -> ./nordvpn-de750.conf
./nordvpn-wg.sh list de             # list German WireGuard servers
```

### Options

| Option     | Description                                                        |
| ---------- | ------------------------------------------------------------------ |
| `-o DIR`   | Write the config to `DIR`. Default: the **current working directory**. |
| `-h`       | Show help.                                                         |

```bash
./nordvpn-wg.sh -o ~/vpn de berlin
```

> Note: output goes to the directory you run the script from unless you pass `-o`.
> It is **not** the script's own directory.

## Running with Nix

The repo is a Nix flake, so you can run it without installing anything:

```bash
# Directly from GitHub:
nix run github:zhuhe6644/nordvpn-wg -- de berlin
nix run github:zhuhe6644/nordvpn-wg -- -o ~/vpn de750

# From a local checkout:
nix run . -- de
nix run . -- list de

# Install into your user profile:
nix profile install github:zhuhe6644/nordvpn-wg
```

**Remember the `--`**: everything after it is passed to the script, so
`-o` and other options reach the generator instead of `nix run`.

## How it works

1. Queries NordVPN's public API for server metadata (country, city, load,
   hostname, endpoint, WireGuard public key).
2. Fetches your private key from the credentials endpoint using
   `NORDVPN_TOKEN`.
3. Writes a standard `wg-quick` config:

   ```ini
   [Interface]
   PrivateKey = <your key>
   Address = 10.5.0.2/32, fd15:53b6:dead::2/64
   DNS = 8.8.8.8, 1.1.1.1

   [Peer]
   PublicKey = <server key>
   AllowedIPs = 0.0.0.0/0, ::/0
   Endpoint = <ip>:51820
   PersistentKeepalive = 25
   ```

The file is created with mode `0600` (and `umask 077`), because it contains
your private key.

## Environment

| Variable          | Description                                  |
| ----------------- | -------------------------------------------- |
| `NORDVPN_TOKEN`   | NordVPN manual-setup access token (required) |

## License

MIT
