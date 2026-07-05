<h1 align="center">Proxmox Mail Gateway<br />
<div align="center">
<a href="https://github.com/dockur/proxmox-mail/"><img src="https://github.com/dockur/proxmox/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
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

- Runs Proxmox Mail Gateway inside Docker
- Provides the familiar Proxmox Mail Gateway web interface
- Filters incoming and outgoing email traffic
- Includes spam and antivirus protection
- Supports quarantine management and mail filtering rules
- Supports DKIM signing for outgoing mail
- Stores mail data and configuration in persistent volumes
- Works on both AMD64 and ARM64 systems

## Usage  🐳

##### Docker Compose:

```yaml
services:
  pmg:
    hostname: pmg
    container_name: pmg
    image: dockurr/proxmox-mail
    environment:
      PASSWORD: "root"
      DOMAIN: "pmg.example.com"
    ports:
      - 25:25
      - 26:26
      - 8006:8006
    volumes:
      - ./config:/etc/pmg
      - ./data:/var/lib/pmg
      - ./spool:/var/spool/pmg
      - ./postgres:/var/lib/postgresql
    restart: always
    stop_grace_period: 2m
```

##### Docker CLI:

```bash
docker run -it --rm --name pmg --hostname pmg -e "PASSWORD=root" -e "DOMAIN=pmg.example.com" -p 25:25 -p 26:26 -p 8006:8006 -v "${PWD:-.}/config:/etc/pmg" -v "${PWD:-.}/data:/var/lib/pmg" -v "${PWD:-.}/spool:/var/spool/pmg" -v "${PWD:-.}/postgres:/var/lib/postgresql" --stop-timeout 120 docker.io/dockurr/proxmox-mail
```

##### GitHub Codespaces:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/proxmox-mail)

## Screenshot 📸

<div align="center">
<a href="https://github.com/dockur/proxmox-mail"><img src="https://raw.githubusercontent.com/dockur/proxmox-mail/master/.github/screenshot.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://127.0.0.1:8006/) using your web browser.

  - Login using the username `root` and the password you specified in the `PASSWORD` environment variable.
  
  Enjoy your time with your brand new Proxmox Mail Gateway, and don't forget to star this repo!

### How do I change the location of the configuration data?

  To change the location of the configuration data, include the following four bind mounts in your compose file:

  ```yaml
volumes:
  - ./config:/etc/pmg
  - ./data:/var/lib/pmg
  - ./spool:/var/spool/pmg
  - ./postgres:/var/lib/postgresql
  ```

  Replace the example paths with the desired folders or named volumes.

### Are there containers available for other Proxmox products?

  Yes, see our [Proxmox VE](https://github.com/dockur/proxmox), [Proxmox Backup Server](https://github.com/dockur/proxmox-backup) and [Proxmox Datacenter Manager](https://github.com/dockur/proxmox-dm) containers.

## Stars 🌟
[![Stargazers](https://raw.githubusercontent.com/star-stats/stars/refs/heads/data/charts/dockur-proxmox-mail.svg)](https://github.com/dockur/proxmox-mail/stargazers)

## Disclaimer ⚖️

*The product names, logos, brands, and other trademarks referred to within this project are the property of their respective trademark holders. This project is not affiliated, sponsored, or endorsed by Proxmox Server Solutions GmbH.*

[build_url]: https://github.com/dockur/proxmox-mail/
[hub_url]: https://hub.docker.com/r/dockurr/proxmox-mail/
[tag_url]: https://hub.docker.com/r/dockurr/proxmox-mail/tags
[pkg_url]: https://github.com/dockur/proxmox-mail/pkgs/container/proxmox-mail

[Build]: https://github.com/dockur/proxmox-mail/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/proxmox-mail/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/proxmox-mail.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/proxmox-mail/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fdockur%2Fproxmox-mail%2Fproxmox-mail.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
