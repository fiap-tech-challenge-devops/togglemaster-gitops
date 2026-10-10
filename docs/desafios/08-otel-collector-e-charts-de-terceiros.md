# Fase 4 — O Collector e como charts de terceiros entram no GitOps

**Projeto:** ToggleMaster (FIAP — Fase 4)
**Escopo:** `platform/`, `applications/otel-collector.yaml`, `charts/base` e os values de `auth-service` e `flag-service`

---

## Visão geral

Primeiro componente de plataforma a entrar por este repositório. Até aqui, tudo que rodava no cluster e não era um dos cinco microsserviços vinha do Terraform (`togglemaster-iac/addons`).

O gatilho não foi o plano: foi um problema em produção. O `flag-service` e o `auth-service` já estavam instrumentados e falhando a cada dez segundos, porque ninguém tinha configurado o destino da telemetria.

Este documento registra duas decisões que valem além do Collector: **como um chart de terceiros entra num repositório GitOps** e **como a pasta `platform/` é organizada** para receber Prometheus, Loki e Grafana depois.

---

## O problema que disparou o passo

```
flag-service: Failed to export traces to localhost:4317 ... Connection refused
auth-service: exporter export timeout ... dial tcp [::1]:4317: connection refused
```

Sem `OTEL_EXPORTER_OTLP_ENDPOINT`, o SDK assume `localhost:4317` e tenta exportar contra o próprio pod. Nada quebrava — as APIs respondiam —, mas quatro pods geravam telemetria, bufferizavam, tentavam, descartavam e registravam erro, em laço.

É o custo de instrumentar a aplicação antes de existir para onde mandar. Em retrospecto, a ordem correta teria sido o Collector primeiro.

---

## Desafio 1 — chart de terceiros não lê `valueFiles` do nosso repositório

As cinco Applications existentes funcionam assim:

```yaml
source:
  repoURL: https://github.com/.../togglemaster-gitops.git
  path: charts/base
  helm:
    valueFiles:
      - ../../apps/auth-service/values-prod.yaml
```

Funciona porque **chart e values moram no mesmo `source`**. O Argo clona o repositório e o caminho relativo resolve dentro da mesma árvore.

Com o Collector, o chart vem do repositório Helm do OpenTelemetry. Se o `source` apontar para lá, o `../../apps/...` deixa de existir: o repositório Helm não contém nossos arquivos, e uma Application tem um `source` só.

### As três saídas avaliadas

| | Values em arquivo | Application igual às atuais | Manifestos próprios juntos | Peça nova |
|---|---|---|---|---|
| **A** — values inline na Application | não | sim | não | nenhuma |
| **B** — Application multi-source com `ref` | sim | não | não | `ref`, marcado beta |
| **C** — chart wrapper com dependência | sim | **sim** | **sim** | um `Chart.yaml` |

### Decisão: C

```yaml
# platform/observability/otel-collector/Chart.yaml
dependencies:
  - name: opentelemetry-collector
    version: 0.175.1
    repository: https://open-telemetry.github.io/opentelemetry-helm-charts
```

E a Application volta a ser **idêntica em formato às cinco existentes**, mudando só o `path`.

Três ganhos: os values ficam em arquivo versionado e revisável em PR; o `Chart.lock` fixa a versão, mesma ideia dos módulos Terraform fixados por tag; e manifestos próprios — dashboard do Grafana, `PrometheusRule`, `ServiceMonitor` — poderão morar em `templates/` do mesmo chart, nascendo e morrendo com o componente de que dependem.

O `.tgz` do subchart fica fora do git: o `Chart.lock` é versionado, e o Argo baixa o pacote no repo-server.

---

## Desafio 2 — um chart por componente, não um chart de observabilidade

A primeira versão era um chart único chamado `observability`, com o Collector como dependência. Prometheus, Loki e Grafana entrariam como dependências do mesmo chart.

Isso traria, de uma vez:

- **uma Application para tudo** — a tela do Argo diria "Degraded" sem dizer qual peça caiu;
- **um `values.yaml` gigante**, com quatro blocos de subchart aninhados;
- **um release Helm único** — subir a versão do Loki redesenharia o Prometheus junto;
- **rollback grosso** — voltar o Grafana voltaria todos.

### Correção

```
platform/
└── observability/
    ├── otel-collector/
    ├── kube-prometheus-stack/   (previsto)
    └── loki/                    (previsto)
```

Um chart e uma Application por componente, agrupados por domínio. A pasta `observability/` é navegação humana — o Argo lê caminho explícito — e deixa espaço para `controllers/`, caso External Secrets e KEDA saiam do Terraform.

**As Applications continuam planas em `applications/`**, e isso não é escolha: a Application raiz lê aquele diretório sem recursão, como registrado em [`03-argocd-app-of-apps.md`](03-argocd-app-of-apps.md). Subpastas não seriam vistas.

A convenção está escrita em [`platform/README.md`](../../platform/README.md).

---

## Desafio 3 — o nome do processor que parecia errado

O preset `kubernetesAttributes` do chart gera o processor como **`k8s_attributes`**, com underscore, e reescreve as pipelines para usar esse nome. A documentação do componente o chama de `k8sattributes`.

Antes de confiar, a configuração renderizada foi validada com o binário do Collector:

```
$ otelcol-contrib validate --config=collector-rendered.yaml
exit=0
```

Um teste que sempre passa não prova nada, então foi feito um **controle negativo** com um nome inventado:

```
Error: 'processors' unknown type: "k8sattributes_inexistente"
  (valid values: [... k8s_attributes k8sattributes ...])
```

O comando detecta erro, e a lista mostra que **os dois nomes são válidos** — são alias. A configuração estava correta.

---

## Resumo das mudanças

| Arquivo | O quê |
|---|---|
| `platform/observability/otel-collector/` | Chart wrapper, Collector 0.175.1, exporter `debug` |
| `platform/README.md` | A convenção de como acrescentar um componente |
| `applications/otel-collector.yaml` | Application, namespace `observability`, `sync-wave: "-2"` |
| `charts/base/templates/deployment.yaml` | Bloco `otel.*` nas env e `podLabels` com os `app.kubernetes.io/*` |
| `charts/base/values.yaml` | Defaults de `otel` — **desligado** por padrão |
| `apps/{auth,flag}-service/values-prod.yaml` | `otel.enabled: true` |
| `.gitignore` | Mantém os `.tgz` dos subcharts fora do git |

O `service.name` sai do nome do release e o `service.version` da tag da imagem, então o padrão de resource attributes entra sem cada serviço repetir configuração. O `service.instance.id` vem do nome do pod pela Downward API, e o `POD_NAME` precisa ser declarado **antes** na lista — o `$(POD_NAME)` é interpolado pelo Kubernetes na ordem em que as variáveis aparecem.

Os três serviços ainda não instrumentados continuam com zero variáveis `OTEL_`, verificado na renderização.

---

## Validação

| Verificação | Resultado |
|---|---|
| Application no Argo | `otel-collector` Synced e Healthy |
| Pod | `Running`, sem restart; coube nos ~380m livres do nó, sem acionar o Karpenter |
| Ruído de exportação | **zero** nos quatro pods |
| Telemetria recebida | 11 lotes de traces, 13 de logs, 39 de métricas |

### O trace entre duas linguagens, no cluster

Uma requisição `GET /flags` entrando pelo ALB, trace `d762e8ee137d`:

```
flag-service   GET /flags              Server   span=f701d7b4   (raiz)
├── flag-service   GET                 Client   span=43ca4e6d   parent=f701d7b4
│   └── auth-service   GET /validate   Server   span=a5decdaf   parent=43ca4e6d
│       ├── auth-service  sql.conn.query          parent=a5decdaf
│       ├── auth-service  sql.rows                parent=a5decdaf
│       └── auth-service  sql.conn.reset_session  parent=a5decdaf
└── flag-service   SELECT              Client   span=c2619d2b   parent=f701d7b4
```

A mesma árvore validada localmente, agora atravessando pods, nós e Services — e cada span carregando `k8s.pod.name`, enriquecimento que o `k8sattributes` acrescenta e que não existe no ambiente local.

### Uma armadilha de diagnóstico

Durante a validação, um `Connection refused` no `flag-service` levou a investigar DNS e Service sem necessidade. O erro era do **segundo exato** em que o Collector subia — transitório. E a busca nos logs usava um formato de indentação que não batia com a saída do `kubectl`, o que fez parecer que nenhum span chegava.

Fica o registro: *"o dado não está chegando"* e *"minha consulta está errada"* produzem o mesmo sintoma.

---

## Pendências

**Portas inúteis no Service.** O chart expõe `6831`, `14250`, `14268` e `9411`, de Jaeger e Zipkin. Os receivers foram desligados no `values.yaml`, mas as portas vêm de uma seção `ports` separada da configuração. É cosmético; pode ser limpo quando o Prometheus entrar.

**Exporter `debug` é temporário.** Ele imprime no log do próprio Collector, o que serve para validar o caminho e não para operar. O Datadog entra como mais um exporter, sem tocar em serviço nenhum — é o ponto da peça estar no meio.

**Agent DaemonSet com `filelog`.** Não foi necessário agora, porque os serviços emitem log por OTLP direto do SDK. Entra na rodada do Loki, para coletar o stdout dos contêineres.
