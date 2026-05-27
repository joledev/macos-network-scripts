# Example: A/B Ethernet vs Wi-Fi

```
Run two quality tests, 30 pings each, against the gateway and 1.1.1.1:

  ./bin/netkit quality --interface en7 --count 30 --json > /tmp/eth.json
  ./bin/netkit quality --interface en0 --count 30 --json > /tmp/wifi.json

Then read both JSON files and produce a 6-row markdown table comparing:

| metric | en7 (ethernet) | en0 (wifi) | winner |

Rows: gateway avg RTT, gateway loss %, gateway jitter (stddev), 1.1.1.1 avg
RTT, 1.1.1.1 loss %, 1.1.1.1 jitter.

End with one sentence recommending which interface to keep as primary.
```
