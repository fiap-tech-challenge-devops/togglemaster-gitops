# Fase 4 — Prometheus efêmero no EKS

**Projeto:** ToggleMaster (FIAP — Fase 4)
**Escopo:** `platform/observability/kube-prometheus-stack/`, `applications/kube-prometheus-stack.yaml` — PR #23

---

## Visão geral

Segundo componente de plataforma a entrar por este repositório, depois do Collector. Entrega o Prometheus com as **métricas de infraestrutura** do cluster: nó (node-exporter), container (cAdvisor do kubelet) e objetos do Kubernetes (kube-state-metrics).

O formato veio pronto do [`08`](08-otel-collector-e-charts-de-terceiros.md): chart wrapper com o `kube-prometheus-stack` como dependência, uma Application própria, namespace `observability`. O trabalho foi outro — o chart, com os valores padrão, **não roda no nosso cluster**. Quatro dos cinco desafios abaixo são o chart pedindo algo que o EKS deste projeto não tem, ou ligando algo que o EKS não oferece.

As métricas das aplicações **não** entram aqui. Elas dependem do exporter `prometheus` no Collector (guia de observabilidade, Parte 2); o Prometheus ficou pronto para lê-las.

---

## Desafio 1 — Não há disco

O `kube-prometheus-stack` assume que haverá onde gravar a série temporal. O nosso cluster não tem: `togglemaster-iac/infra/main.tf` declara `enable_ebs_csi_driver = false`, e sem o driver **nenhum PersistentVolumeClaim é atendido**. Um PVC ficaria `Pending` e o pod do Prometheus nunca subiria.

### As duas saídas

| | Dado sobrevive a restart | Peças novas | Efeito no destroy |
|---|---|---|---|
| **A** — ligar o EBS CSI driver | sim | add-on, IRSA, StorageClass | volumes EBS fora do `tfstate`, que podem ficar órfãos |
| **B** — `emptyDir` com retenção curta | não | nenhuma | nenhum |

### Decisão: B

O ambiente é **destruído toda noite**. Um dado que não sobrevive ao destroy não justifica um driver, uma role e uma classe de armazenamento — nem o risco de volume órfão, o mesmo problema que o `eks-cleanup` já trata para ALBs e nós do Karpenter.

```yaml
storageSpec:
  emptyDir:
    sizeLimit: 4Gi
retention: 24h
retentionSize: 3GB
```

O `retentionSize` fica **abaixo** do `sizeLimit` de propósito: o Prometheus descarta bloco antigo antes de o kubelet despejar o pod por excesso de disco.

O custo aceito: se o pod reinicia — inclusive por interrupção de spot —, o histórico recomeça. Para uma demonstração dentro de uma sessão, isso não muda nada. E o cluster continua sem nenhum PVC, que é o fato em que a [ADR 0025](https://github.com/fiap-tech-challenge-devops/.github/blob/main/docs/decisoes/0025-baseline-em-spot.md) se apoia para aceitar spot.

A mesma pendência existe para o Loki, e a mesma resposta serve.

---

## Desafio 2 — As CRDs não cabem numa annotation

O chart traz dez CRDs do Prometheus Operator. O apply padrão do Argo CD é client-side, e grava o manifesto inteiro na annotation `kubectl.kubernetes.io/last-applied-configuration`. O Kubernetes limita o total de annotations de um objeto a **256 KiB**.

Medido no manifesto renderizado, em JSON compacto — o formato da annotation:

| CRD | Tamanho |
|---|---|
| `prometheuses` | **486 KiB** |
| `prometheusagents` | 415 KiB |
| `scrapeconfigs` | 377 KiB |
| `alertmanagerconfigs` | 359 KiB |
| `alertmanagers` | 355 KiB |
| `thanosrulers` | 349 KiB |
| `servicemonitors`, `podmonitors`, `probes`, `prometheusrules` | 8 a 42 KiB |

Seis das dez estouram. Sem mudança, o primeiro sync falha com `metadata.annotations: Too long: must have at most 262144 bytes`.

### Decisão

```yaml
syncOptions:
  - ServerSideApply=true
```

O server-side apply registra a posse dos campos em `managedFields` e não usa a annotation. É a única linha da Application que difere das outras.

---

## Desafio 3 — O que o chart liga e o EKS não tem

Com os valores padrão, o chart monitora o cluster inteiro, inclusive o que o EKS não expõe.

**Control plane.** Scheduler, controller-manager e etcd são gerenciados pela AWS e não são alcançáveis de dentro do cluster. O kube-proxy só expõe métricas em `127.0.0.1` do próprio nó. Ligados, os quatro virariam alvos `DOWN` permanentes. Desligados no values.

As regras de alerta desses componentes **somem junto** — verificado no template de cada regra, que testa `kubeEtcd.enabled`, `kubeScheduler.enabled` e assim por diante. As do Alertmanager são a exceção: o template não testa `alertmanager.enabled`, e por isso precisam de `defaultRules.rules.alertmanager: false` explícito.

As **regras de gravação** ficam. Os dashboards de Kubernetes do Grafana consultam as séries que elas pré-calculam.

**Webhooks de admissão.** Eles validam `PrometheusRule` antes de aplicar. O certificado nasce num Job de hook do Helm, que depois **corrige o `caBundle` no cluster**. O Argo CD compara com o Git, vê o campo diferente e marca a Application como `OutOfSync` — para sempre. Desligados, e o TLS do operator sai junto, porque existe para servir esses webhooks. A renderização confirma: nenhum hook, e nenhuma referência ao secret do certificado.

O custo aceito: uma `PrometheusRule` inválida não é recusada no apply. Ela aparece no log do operator.

**Grafana e Alertmanager.** Vêm no mesmo chart e ficam desligados nesta entrega. O Grafana tem card próprio e liga neste mesmo `values.yaml`. O Alertmanager depende da decisão de alerta, e o guia de observabilidade recomenda que o caminho do alerta passe pelo Datadog, que é externo ao cluster que pode estar com problema.

---

## Desafio 4 — Push ou pull

O Prometheus 3 sabe **receber** métricas por OTLP, e a primeira versão do values ligava esse receptor: o Collector empurraria para `/api/v1/otlp/v1/metrics`.

Antes de abrir o PR, a leitura do guia de observabilidade mostrou que a decisão já estava tomada no outro sentido: **o Prometheus puxa**. O Collector expõe um exporter `prometheus` na porta `8889`, e um `ServiceMonitor` diz ao Prometheus onde coletar.

As duas formas funcionam. O receptor OTLP saiu do values, porque a decisão registrada vincula quem vem depois — e a mudança de rumo seria do card do Collector, não deste.

O que este componente precisa para o pull funcionar ficou:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
ruleSelectorNilUsesHelmValues: false
probeSelectorNilUsesHelmValues: false
scrapeConfigSelectorNilUsesHelmValues: false
```

Com os padrões `true`, o Prometheus só lê `ServiceMonitor` que carregue o label `release=kube-prometheus-stack` — e **ignora em silêncio** os do Collector e do Loki.

---

## Desafio 5 — Capacidade

O guia previa que o nó não comportaria a stack e o Karpenter subiria outro. Com `resources.requests` em todos os componentes, o Karpenter tem com o que dimensionar:

| Componente | CPU | Memória (request / limit) |
|---|---|---|
| Prometheus | 100m | 1Gi / 2Gi |
| Operator | 20m | 64Mi / 256Mi |
| kube-state-metrics | 10m | 64Mi / 128Mi |
| node-exporter (por nó) | 10m | 32Mi / 64Mi |

O Prometheus não tem limite de CPU **de propósito**: a compactação do TSDB é em rajada, e um limite viraria throttling justamente nela.

No EKS, **coube nos dois nós spot do baseline**, sem o Karpenter subir nó. O baseline de dois nós da [ADR 0025](https://github.com/fiap-tech-challenge-devops/.github/blob/main/docs/decisoes/0025-baseline-em-spot.md) é o que absorveu.

---

## Armadilhas de diagnóstico

Nenhuma é do Prometheus. Todas apareceram na validação na AWS e fizeram parecer que algo estava quebrado.

**Contador lido como consumo.** `container_cpu_usage_seconds_total` sozinho é um **contador** — segundos de CPU acumulados desde que o container nasceu. Sobe sempre, com ou sem tráfego. Taxa de uso é só com `rate`:

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="togglemaster", container!=""}[5m]))
```

**`/targets` não mostra valor.** A página diz se a coleta funciona, não o que foi coletado. Os valores ficam em *Query*.

**Script de tráfego sem permissão.** O `gerar-trafego.sh` do `togglemaster-iac` está versionado como `100644`, sem bit de execução. Chamado direto, dá `permission denied`; com `bash` na frente, funciona.

---

## Resumo das mudanças

| Arquivo | O quê |
|---|---|
| `platform/observability/kube-prometheus-stack/Chart.yaml` | Wrapper, `kube-prometheus-stack` **92.10.1** |
| `platform/observability/kube-prometheus-stack/Chart.lock` | Fixa a versão; o `.tgz` fica fora do git |
| `platform/observability/kube-prometheus-stack/values.yaml` | `emptyDir`, control plane e webhooks desligados, seletores abertos, `requests` |
| `applications/kube-prometheus-stack.yaml` | Application, `sync-wave: "-3"`, `ServerSideApply=true` |
| `platform/README.md` | Tira o "(previsto)" do componente |

O `sync-wave: "-3"` põe a Application antes do Collector (`-2`): as CRDs de `ServiceMonitor` e `PrometheusRule` nascem aqui. No app-of-apps, a wave ordena a **criação** das Applications, não espera que fiquem saudáveis.

---

## Validação

### Estática

| Verificação | Resultado |
|---|---|
| `helm lint` | sem erro |
| Renderização como o Argo CD faz (`--namespace observability --kube-version 1.34.0 --include-crds`) | 66 objetos |
| PVC, LoadBalancer ou Ingress | **nenhum** — nada gera custo nem fica órfão no destroy |
| Hooks do Helm | nenhum |
| Regras de componentes desligados | nenhuma |

### AWS — EKS 1.34, 25/10/2026

Ambiente subido pelo `IaC — Apply`, Application aplicada à mão apontando para a branch. Como ela não veio do Git, o app `root` não a apaga; no merge, ele a adota e troca o `targetRevision` para `main`.

| Verificação | Resultado |
|---|---|
| Applications | **8/8** `Synced` e `Healthy` |
| Pods | operator, kube-state-metrics, Prometheus `2/2`, **um node-exporter por nó** |
| Alvos | **16/16 `up`** — apiserver ×2, coredns ×2, operator, prometheus ×2, kube-state-metrics, kubelet ×6 (3 por nó), node-exporter ×2 |
| Nós | os 2 spot do baseline (`t3a.large`), sem nó do Karpenter |
| CPU / memória por nó | 60% e 57% logo após o apply / 26% e 16% |
| Pods por fase | 39 `Running`, 3 `Succeeded` (Jobs de migração) |
| Destroy | `IaC — Destroy` #35 verde em 15m16s; `list-clusters` vazio |

### A CPU respondendo à carga

Com o `gerar-trafego.sh` a 1 req/s, consultado em janelas de 5 minutos:

| Pod | 11:17 (sem tráfego) | 11:22 | 11:27 |
|---|---|---|---|
| flag-service ×2 | 0m | 1–2m | 4m |
| targeting-service ×2 | 0m | 1m | 3–4m |
| evaluation-service ×2 | 0m | 0m | 2m |
| auth-service ×2 | 0m | 0m | 1m |

A ordem bate com o fan-out: o `evaluation` chama `flag` e `targeting`, e os dois validam a chave no `auth`, que faz menos trabalho por chamada.

Passando o gerador a `0.3`, as curvas subiram em degrau até a faixa de 2 a 12m por pod.

No mesmo gráfico aparecem segmentos curtos e altos (16–26m): são **réplicas diferentes do `analytics-service`**, criadas e removidas pelo KEDA conforme a fila enche. O Prometheus registrou o autoscaling sem configuração nenhuma — cada réplica nova é uma série nova.

---

## Pendências

**A ponte com o Collector.** O exporter `prometheus` em `0.0.0.0:8889` e a porta no Service são do card do Collector. O `ServiceMonitor` que aponta para ela mora, pela convenção do [`platform/README.md`](../../platform/README.md), em `templates/` deste wrapper. Sem essa ponte, o dashboard não tem a taxa de requisições dos serviços.

**O Grafana.** Liga neste mesmo `values.yaml`. O PR #22 nasceu com os mesmos três arquivos, e o caminho combinado é rebase em cima da `main`, mantendo só o bloco do Grafana.

**O Loki.** Os `ServiceMonitor` dele serão lidos sem label extra. Como as CRDs vêm desta Application e a wave não espera saúde, vale um `retry` na Application do Loki.

**O `helm_release` desligado no Terraform.** A [ADR 0003](https://github.com/fiap-tech-challenge-devops/.github/blob/main/docs/decisoes/0003-observabilidade-no-gitops.md) diz que ele sai, e ele continua em `togglemaster-iac/addons/controllers.tf`. Merge em `addons/**` dispara o apply completo.

**O `evaluation-service` não tem HPA.** A consulta de réplicas encontrou só o HPA do KEDA, do `analytics-service`. A história do desafio é um HPA escalando o `evaluation-service`; para mostrá-la, ele precisa existir.

**Versão do chart.** Fixada na 92.10.1, a validada. A 92.11.0 já saiu; subir é um PR próprio, com a mesma validação.
