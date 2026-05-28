# NetBox as netkit's source of truth

netkit is the **collector**; NetBox is the **source of truth** (IPAM/DCIM) that
documents the whole building — sites, racks, devices, interfaces, IPs, VLANs,
cables. You scan with `netkit recon`, then push the inventory into NetBox.

## 1. Bring up NetBox (quickstart)

```sh
cd deploy/netbox
cp .env.example .env
# edit .env: set strong DB_PASSWORD / REDIS_PASSWORD / SECRET_KEY (>=50 chars),
# a SUPERUSER_PASSWORD, and a 40-hex SUPERUSER_API_TOKEN (openssl rand -hex 20)
docker compose up -d
# first boot runs migrations + creates the superuser (~1-2 min)
docker compose logs -f netbox      # wait for "Application startup complete"
```

Open <http://localhost:8000> and log in with `SUPERUSER_NAME` /
`SUPERUSER_PASSWORD`. The `SUPERUSER_API_TOKEN` you set is already active under
**Admin → API Tokens**.

> Production: use the official, fully-featured stack instead —
> <https://github.com/netbox-community/netbox-docker> (HTTPS, housekeeping,
> backups). This compose is a minimal local quickstart.

## 2. Point netkit at it

```sh
export NETKIT_NETBOX_URL="http://localhost:8000"
export NETKIT_NETBOX_TOKEN="<the SUPERUSER_API_TOKEN from .env>"
```

## 3. Scan and push

```sh
# Whole building: discover segments, then scan every VLAN range
./bin/netkit routes                              # which subnets/VLANs you reach
./bin/netkit recon --active --subnets 10.0.10.0/24,10.0.20.0/24,10.0.30.0/24

# Push the latest recon inventory into NetBox (create-or-update IP addresses)
./bin/netkit netbox-export --push
```

Re-running reconciles (updates existing IPs instead of duplicating). For a dry
look without a server, emit CSVs instead:

```sh
./bin/netkit netbox-export --csv      # output/netbox-<ts>-{ips,devices}.csv
```

Then in NetBox: **IPAM → IP Addresses → Import** (the `-ips.csv`). The devices
CSV references device-role / manufacturer / device-type / site by name, so
create those first (or edit the CSV) before **DCIM → Devices → Import**.

## 4. (Optional) port-level topology

NetBox documents *what exists*; for *which switch port each device is on*, point
**Netdisco** (SNMP + bridge-FDB + LLDP) at your managed switches and feed its
findings into NetBox, or use `netkit lldp` / `netkit snmp` where available.

## Tear down

```sh
docker compose down            # keep data
docker compose down -v         # also delete the volumes (postgres/redis/media)
```
