# NAT-HUB-WEB-LOCK

This standalone script restricts the NAT-IP-Rotation-Hub Master Web interface to a private host address or loopback. It does not install, configure, or modify Nginx Proxy Manager.

Use it when NPM terminates HTTPS and proxies to the Master over HTTP. The public Master Web port is closed by binding the service to the Docker bridge address, normally `172.17.0.1`. The Master node signaling port, normally `31177`, is left unchanged for Relay and Agent nodes.

## Install and run

On the Master server, run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/NAT-HUB-WEB-LOCK/main/lock-master-web.sh -o /tmp/lock-master-web.sh
chmod 700 /tmp/lock-master-web.sh
/tmp/lock-master-web.sh
```

NPM should proxy to:

```text
http://172.17.0.1:31178
```

If the Docker bridge is not detected, pass the private address explicitly:

```bash
/tmp/lock-master-web.sh --bind 172.17.0.1
```

If NPM uses host networking, use loopback instead:

```bash
/tmp/lock-master-web.sh --loopback
```

After the change:

* `https://your-domain.example` should continue to work through NPM.
* `http://PUBLIC_IP:31178` should refuse the connection.
* Relay and Agent nodes should continue using the Master signaling address on `31177`.

## Check and restore

```bash
/tmp/lock-master-web.sh --status
/tmp/lock-master-web.sh --restore
```

The script saves the original systemd unit under `/etc/nat-hub` before changing it. It refuses public bind addresses and requires the selected private address to be assigned to the host.
