# platform

Componentes de plataforma — o que sustenta os microsserviços, e não os microsserviços em si.

```
platform/
└── observability/
    ├── otel-collector/     recebe e roteia a telemetria
    ├── kube-prometheus-stack/   Prometheus (Alertmanager e Grafana no mesmo chart, ainda desligados)
    └── loki/               (previsto) logs
```

A pasta de domínio (`observability/`) é navegação humana — o Argo CD lê caminho explícito. Ela existe para que outros domínios caibam depois, como `controllers/`, caso External Secrets e KEDA saiam do Terraform.

## A convenção

**Um chart e uma Application por componente.** Não um chart único com várias dependências.

O motivo é granularidade: cada componente tem saúde, sync e rollback próprios no Argo. Num chart único, subir a versão do Loki redesenharia o Prometheus junto, e a tela do Argo mostraria uma caixa só, sem dizer qual peça quebrou.

**Chart de terceiros entra como dependência de um chart nosso**, nunca como Application apontando direto para o repositório Helm:

```yaml
# <componente>/Chart.yaml
dependencies:
  - name: opentelemetry-collector
    version: 0.175.1
    repository: https://open-telemetry.github.io/opentelemetry-helm-charts
```

Isso mantém os values em arquivo versionado, deixa a Application idêntica em formato às dos microsserviços, e permite manifestos próprios em `templates/`. O `Chart.lock` fixa a versão — mesma ideia dos módulos Terraform fixados por tag.

**Manifestos nossos ficam no `templates/` do componente de que dependem.** O dashboard do Grafana, as `PrometheusRule` e os `ServiceMonitor` vão no wrapper do `kube-prometheus-stack`: nascem e morrem com ele, na ordem certa, sem precisar de sync wave.

**As Applications ficam planas em `applications/`.** A Application raiz lê aquele diretório sem recursão, então subpastas não seriam vistas.

## Acrescentando um componente

1. `platform/<domínio>/<componente>/Chart.yaml` com a dependência
2. `values.yaml` com a configuração do subchart
3. `helm dependency update` na pasta, e versione o `Chart.lock` — os `.tgz` ficam fora do git
4. `applications/<componente>.yaml`, copiando um existente
5. `argocd.argoproj.io/sync-wave` se a ordem importar

## Namespace

Todos os componentes de observabilidade vão para o namespace `observability`. Pasta e namespace não precisam coincidir, e um namespace único simplifica a leitura no `kubectl` e o `k8sattributes`.
