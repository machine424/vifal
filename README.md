# `vifal`

Read-only FUSE mount that exposes Kubernetes container filesystems locally.

```bash
# uses the current kubeconfig context
$ vifal /mnt/foo-cluster &

$ ls /mnt/foo-cluster/
default  kube-system  monitoring  apps

$ ls /mnt/foo-cluster/apps/web-abc12/app/etc/
hostname  hosts  resolv.conf

$ cat /mnt/foo-cluster/apps/web-abc12/app/etc/hostname
web-abc12

$ diff /mnt/foo-cluster/apps/worker-a/app/etc/app.conf \
       /mnt/foo-cluster/apps/worker-b/app/etc/app.conf

$ vifal unmount /mnt/foo-cluster
```

## Design

```
MOUNTPOINT/<namespace>/<pod>/<container>/<path inside the container>
```

Browsing into a container gives you its `/`. Namespaces and Pods sync in real time via Kubernetes watches.

Under the hood, `vifal` maintains a persistent `exec` session per container and runs shell commands (`find`, `stat`, `dd`) to serve FUSE operations. This means it is a debugging tool, not something you'd use for heavy I/O.

Listings and attributes are cached by the kernel for `--attr-ttl` to reduce round trips. Negative lookups are cached for half the TTL. File content is never cached (`DIRECT_IO`), so reads always return fresh data.

## Install

Works on Linux and macOS.

- Linux: install `fuse3`.
- macOS: install [macFUSE](https://github.com/macfuse/macfuse/wiki/Getting-Started). The mount appears as a network volume, so your terminal may need [access to network volumes](https://github.com/macfuse/macfuse/issues/690#issuecomment-1527424231).

```bash
$ go install github.com/machine424/vifal@latest
```

Or from source:

```bash
$ git clone https://github.com/machine424/vifal.git && cd vifal
$ make build
```

## Prerequisites

Minimum RBAC on the target cluster:

| Resource | Verbs |
|---|---|
| `namespaces` | `list`, `watch` |
| `pods` | `list`, `watch` |
| `pods/exec` | `create` |

Containers must have `sh`, `stat`, `find`, and `dd`. Most images do (Debian, Alpine, BusyBox). Distroless and scratch images won't work.

## Usage

```bash
$ vifal --help
$ vifal unmount --help
```

## Special thanks

`vifal` relies heavily on [`go-fuse`](https://github.com/hanwen/go-fuse), the Go FUSE bindings it is built on. Special thanks to [Han-Wen Nienhuys](https://github.com/hanwen).
