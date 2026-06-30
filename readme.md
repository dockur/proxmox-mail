<h1 align="center">Proxmox Mail Gateway<br />
<div align="center">
<a href="https://github.com/dockur/proxmox-mail/"><img src="https://github.com/dockur/proxmox-mail/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Package]][pkg_url]
[![Pulls]][hub_url]

</div></h1>

Proxmox Mail Gateway inside a Docker container.

## Features ✨

- **Centralized management** — Manage any number of [Proxmox VE](https://github.com/dockur/proxmox/) nodes using a modern web-interface
- **Resource monitoring** — A global dashboard visualizes the state of every node, highlighting potential issues
- **Easy backups** — Stores all your configuration in a volume mount, for easy backup and restore
- **Task aggregation** — Centralized access to task logs across the entire infrastructure for auditing and troubleshooting
- **Cross-cluster migration** — Execute live migrations of virtual guests between nodes
- **Update management** — Monitor available updates and security patches across the whole fleet

## Usage  🐳

##### Via Docker Compose:

```yaml
services:
  pdm:
    hostname: pmg
    container_name: pmg
    image: dockurr/proxmox-mail
    environment:
      PASSWORD: "root"
    ports:
      - 8443:8443
    volumes:
      - ./config:/etc/proxmox-datacenter-manager
      - ./data:/var/lib/proxmox-datacenter-manager
    restart: always
    privileged: true
    stop_grace_period: 2m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name pmg --hostname pmg --privileged -e "PASSWORD=root" -p 8443:8443 -v "${PWD:-.}/config:/etc/proxmox-datacenter-manager" -v "${PWD:-.}/data:/var/lib/proxmox-datacenter-manager" --stop-timeout 120 docker.io/dockurr/proxmox-mail
```

##### Via Github Codespaces:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/proxmox-mail)

## Screenshot 📸

<div align="center">
<a href="https://github.com/dockur/proxmox-mail"><img src="https://raw.githubusercontent.com/dockur/proxmox-mail/master/.github/screenshot.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8443](http://127.0.0.1:8443/) using your web browser.

  - Login using the username `root` and the password you specified in the `PASSWORD` environment variable.
  
  Enjoy your time with your brand new Proxmox Datacenter Manager, and don't forget to star this repo!

### How do I change the location of the configuration data?

  To change the location of the configuration data, include the following two bind mounts in your compose file:

  ```yaml
volumes:
  - ./config:/etc/proxmox-datacenter-manager
  - ./data:/var/lib/proxmox-datacenter-manager
  ```

  Replace the example paths `./config` and `./data` with the desired folders or named volumes.

### Are there containers available for other Proxmox products?

  Yes, see our [Proxmox VE](https://github.com/dockur/proxmox) and [Proxmox Backup Server](https://github.com/dockur/proxmox-backup) containers.

## Acknowledgements 🙏

Special thanks to [willmortimer](https://github.com/willmortimer), [wofferl](https://github.com/wofferl) and [LongQT-sea](https://github.com/LongQT-sea), this project would not exist without their invaluable work.

## Stars 🌟
[![Stargazers](https://raw.githubusercontent.com/star-stats/stars/refs/heads/data/charts/dockur-proxmox-mail.svg)](https://github.com/dockur/proxmox-mail/stargazers)

[build_url]: https://github.com/dockur/proxmox-maik/
[hub_url]: https://hub.docker.com/r/dockurr/proxmox-mail/
[tag_url]: https://hub.docker.com/r/dockurr/proxmox-mail/tags
[pkg_url]: https://github.com/dockur/proxmox-mail/pkgs/container/proxmox-mail

[Build]: https://github.com/dockur/proxmox-mail/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/proxmox-mail/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/proxmox-mail.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/proxmox-mail/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fdockur%2Fproxmox-mail%2Fproxmox-mail.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
