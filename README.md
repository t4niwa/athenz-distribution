# athenz-distribution

This is an unofficial repository to provide tools, packages and instructions for [Athenz](https://www.athenz.io).

This repository is currently privately owned and maintained by [ctyano](https://github.com/ctyano).

Stars and Pull Requests are always welcome.

To learn more about this repository, you may refer to [the documentation of this repository](docs).

## Quick start on a KinD cluster

```
make up
```

This brings up the full Athenz ecosystem on a local KinD cluster with a single command.

You can access Athenz UI at http://localhost:3000 by forwarding requests.

```
kubectl -n athenz port-forward deployment/athenz-ui 3000:3000
```

To tear down the cluster:

```
make down
```

## Minimum setup on a Kubernetes cluster

```
make deploy-athenz deploy-identityprovider deploy-workloads
```

You can access Athenz UI at http://localhost:3000 by forwarding requests.

```
kubectl -n athenz port-forward deployment/athenz-ui 3000:3000
```

To see how Athenz authorization scenarios work, check out the [Kubernetes Showcase](docs/SHOWCASES_KUBERNETES.md) to run the entire ecosystem.
