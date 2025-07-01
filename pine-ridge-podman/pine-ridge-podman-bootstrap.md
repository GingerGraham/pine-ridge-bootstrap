# Pine Ridge Podman Bootstrap

This bootsrap script is used to configure a Podman container host to deploy Podman quadlets in a gitops style.

The design intention here is that the deployment repo itself is a private GitHub repo and this bootstrap script generates a deploy key for the host to use to pull the repo. The deploy key is then added to the repo as a deploy key manually.

This bootstrap script is highly opinionated to the design requirements of the Pine Ridge Podman project and may not be suitable for other use cases.

# Usage

```bash
curl -sSL https://raw.githubusercontent.com/GingerGraham/pine-ridge-bootstrap/main/pine-ridge-podman/bootstrap.sh | bash -s -- https://github.com/GingerGraham/pine-ridge-podman.git
```
