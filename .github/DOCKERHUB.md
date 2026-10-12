# Tavazon · تـوازن

**Keep an asymmetric hosting quota in balance by sending shaped, distributed junk traffic.**

[![Release build](https://img.shields.io/github/actions/workflow/status/salehi/tavazon/release.yml?label=release%20build&logo=githubactions&logoColor=white)](https://github.com/salehi/tavazon/actions/workflows/release.yml)
[![Docker image](https://img.shields.io/docker/v/s4l3h1/tavazon?sort=semver&label=docker&logo=docker&logoColor=white)](https://hub.docker.com/r/s4l3h1/tavazon/tags)
[![Image size](https://img.shields.io/docker/image-size/s4l3h1/tavazon/latest?logo=docker&logoColor=white&label=image%20size)](https://hub.docker.com/r/s4l3h1/tavazon/tags)
[![GitHub](https://img.shields.io/badge/source-salehi%2Ftavazon-181717?logo=github)](https://github.com/salehi/tavazon)

Tavazon reads your server's real network counters, works out how much **upload** you
are short of the ratio your provider expects (for example 1:8), and makes up the
difference with random UDP datagrams. The datagrams are spread across many IPs in
AS numbers you choose, and their volume follows a smooth day-and-night curve. A
web dashboard is built in.

Source, full documentation and the ethical limits the tool keeps to:
**<https://github.com/salehi/tavazon>**

## Image

| | |
|---|---|
| Base | `scratch`: one static, CGO-free, UPX-packed binary and a default config |
| Size | about 2–3 MB compressed |
| Platforms | `linux/amd64`, `linux/arm64`, `linux/arm/v7` |
| Port | `8081` (dashboard, bound to `127.0.0.1` by default) |
| Volume | `/data` (state, metering, logs) |

Tags: `latest`, plus `X.Y.Z`, `X.Y` and `X` for every release.

## Quick start (Docker Compose)

```sh
mkdir tavazon && cd tavazon
curl -fsSLO https://raw.githubusercontent.com/salehi/tavazon/main/docker-compose.yml
curl -fsSL  https://raw.githubusercontent.com/salehi/tavazon/main/config.example.json -o config.json
mkdir -p data maxmind_files   # put GeoLite2-ASN.mmdb and GeoLite2-Country.mmdb here
docker compose up -d
```

Create `config.json` **before** the first start. Otherwise Docker creates a
directory with that name.

## Plain Docker

```sh
docker run -d --name tavazon --restart always --network host \
  -v "$PWD/config.json:/config.json" \
  -v "$PWD/data:/data" \
  -v "$PWD/maxmind_files:/maxmind_files:ro" \
  s4l3h1/tavazon:latest
```

- **`--network host` is required.** Tavazon must read the *host's* NIC counters and
  send from the host's IP.
- `config.json` is mounted read-write because the dashboard saves changes to it.
- Any setting can be overridden with a `TAVAZON_<SECTION>_<FIELD>` environment
  variable, for example `TAVAZON_TARGET_RATIO_MULTIPLIER=8`.

## GeoLite2 databases

The free MaxMind **GeoLite2 ASN** and **GeoLite2 Country** `.mmdb` files are not
included, because their licence forbids redistribution. Download them from
<https://www.maxmind.com/en/geolite2/signup> into `maxmind_files/`. Without them the
dashboard still runs, but the uploader stays idle.

## Dashboard

Open `http://127.0.0.1:8081` on the host, or reach it remotely through an SSH tunnel:
`ssh -L 8081:127.0.0.1:8081 your-server`. If you bind it to a non-local address,
you **must** set `web.auth_token`.

## License

MIT. See <https://github.com/salehi/tavazon/blob/main/LICENSE>.
