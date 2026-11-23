# mem0 chart

A shared Mem0 server for memory consolidation on the open source path. It's an alternative to the default, which runs Mem0 as a library inside the agent; read this only if several clients that aren't Strands agents need one Mem0 service.

Its Application, [`gitops/platform/open-source/alternatives/mem0-server/62-consolidation.yaml`](../../platform/open-source/alternatives/mem0-server/62-consolidation.yaml), isn't synced where it sits; move it into `gitops/platform/open-source/` to use it. Each value is documented in [`values.yaml`](values.yaml), and [Memory for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html) compares the server with the library.

## What it renders

| Template | Objects |
|---|---|
| `templates/deployment.yaml` | The `mem0` ServiceAccount, Deployment, and Service |

## Values you set

| Key | Effect |
|---|---|
| `image.repository`, `image.tag` | An image you build from the upstream source. Both are empty, and the chart refuses to render until they're set, because the published image has only a `latest` tag to pin. |
| `llm` | The gateway endpoint and model Mem0 calls to consolidate. `llm.baseUrl` is required, and Mem0 needs its own entry in the gateway's `agents` map. |
| `database` | The Secret holding the Postgres and vector store URLs, for the pgvector cluster `61-semantic-recall.yaml` creates. |
| `replicaCount`, `resources`, `service`, `podSecurityContext` | The server's size and exposure. |
