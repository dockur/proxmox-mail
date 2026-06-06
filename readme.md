<h1 align="center">Proxmox Datacenter Manager<br />
<div align="center">
<a href="https://github.com/dockur/proxmox-dm/"><img src="https://github.com/dockur/proxmox-dm/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Pulls]][hub_url]

</div></h1>

Proxmox Datacenter Manager inside a Docker container.

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
    hostname: pdm
    container_name: pdm
    image: dockurr/proxmox-dm
    environment:
      PASSWORD: "root"
    ports:
      - 8443:8443
    volumes:
      - ./config:/etc/proxmox-datacenter-manager
      - ./pdm:/var/lib/proxmox-datacenter-manager
    restart: always
    privileged: true
    stop_grace_period: 2m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name pdm --hostname pdm --privileged -e "PASSWORD=root" -p 8443:8443 -v "${PWD:-.}/config:/etc/proxmox-datacenter-manager" -v "${PWD:-.}/pdm:/var/lib/proxmox-datacenter-manager" --stop-timeout 120 docker.io/dockurr/proxmox-dm
```

##### Via Github Codespaces:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/proxmox-dm)

## Screenshot 📸

<div align="center">
<a href="https://github.com/dockur/proxmox-dm"><img src="https://raw.githubusercontent.com/dockur/proxmox-dm/master/.github/screenshot.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8443](http://127.0.0.1:8443/) using your web browser.

  - Login using the username `root` and the password you specified in the `PASSWORD` environment variable.
  
  Enjoy your time with your brand new Proxmox Datacenter Manager installation, and don't forget to star this repo!

### How do I change the location of the configuration data?

  To change the location of your Proxmox VE configuration data, include the following two bind mounts in your compose file:
  
  ```yaml
volumes:
  - ./config:/etc/proxmox-datacenter-manager
  - ./pdm:/var/lib/proxmox-datacenter-manager
  ```

  Replace the example paths `./pdm` and `./config` with the desired storage folders or named volumes.

### Is there also Proxmox VE in a container?

  Yes, see our [dockur/proxmox](https://github.com/dockur/proxmox) repository.

### How do I verify if my system supports the KVM virtualization used by Proxmox?

  First check if your software is compatible using this chart:

  | **Product**  | **Linux** | **Win11** | **Win10** | **macOS** |
  |---|---|---|---|---|
  | Docker CLI        | ✅   | ✅       | ❌        | ❌ |
  | Docker Desktop    | ❌   | ✅       | ❌        | ❌ | 
  | Podman CLI        | ✅   | ✅       | ❌        | ❌ | 
  | Podman Desktop    | ✅   | ✅       | ❌        | ❌ | 

  After that you can run the following commands in Linux to check your system:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM cannot be used, please check whether:

  - the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS.

  - you enabled "nested virtualization" if you are running the container inside a virtual machine.

  - you are not using a cloud provider, as most of them do not allow nested virtualization for their VPS's.

## Acknowledgements 🙏

Special thanks to [LongQT-sea](https://github.com/LongQT-sea), this project would not exist without his invaluable work.

## Stars 🌟
[![Stars](https://starchart.cc/dockur/proxmox-dm.svg?variant=adaptive)](https://starchart.cc/dockur/proxmox-dm)

[build_url]: https://github.com/dockur/proxmox-dm/
[hub_url]: https://hub.docker.com/r/dockurr/proxmox-dm/
[tag_url]: https://hub.docker.com/r/dockurr/proxmox-dm/tags
[pkg_url]: https://github.com/dockur/proxmox-dm/pkgs/container/proxmox-dm

[Build]: https://github.com/dockur/proxmox-dm/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/proxmox-dm/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/proxmox-dm.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/proxmox-dm/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fdockur%2Fproxmox-dm%2Fproxmox-dm.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
