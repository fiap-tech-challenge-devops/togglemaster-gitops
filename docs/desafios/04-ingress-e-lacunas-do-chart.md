# Fase 3 — Ingress no chart e as lacunas que ele revelou

**Projeto:** ToggleMaster (FIAP — Fase 3)
**Escopo:** Template de Ingress em `charts/base`, correção do `envFrom` e levantamento do que falta

---

## Visão geral

Depois de destravar o app-of-apps ([03](03-argocd-app-of-apps.md)), o chart ainda não expunha nada: os serviços subiriam como `ClusterIP`, alcançáveis só de dentro do cluster.

O `togglemaster-platform` já tinha um manifesto de Ingress escrito à mão. Adaptá-lo ao modelo do Argo CD exigiu uma decisão de desenho, e a validação da adaptação revelou um bug que teria impedido **qualquer** deployment de subir.

---

## Desafio 1 — um Ingress compartilhado num chart por serviço

### O manifesto original

`togglemaster-platform/k8s/ingress.yaml` era **um único Ingress** roteando por path para quatro serviços:

```yaml
kind: Ingress
metadata:
  name: togglemaster
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /validate   → auth-service:8001
          - path: /admin      → auth-service:8001
          - path: /flags      → flag-service:8002
          - path: /rules      → targeting-service:8003
          - path: /evaluate   → evaluation-service:8004
```

Funciona bem com `kubectl apply`. Não encaixa aqui: o `charts/base` é instalado **uma vez por serviço**, e cada release conhece apenas a si mesma. Um Ingress que enumera cinco backends não tem dono natural.

### As alternativas

| abordagem | consequência |
|---|---|
| Ingress avulso numa `Application` separada | uma release "plataforma" fora do chart; roteamento longe do serviço que ele expõe |
| Um Ingress por serviço, sem agrupamento | **quatro ALBs**, um por Ingress |
| Um Ingress por serviço, agrupados | um ALB só, configuração junto do serviço |

A segunda foi descartada por custo: o ALB tem taxa horária fixa, e três a mais somam cerca de **$0,07/h** só de taxa, antes das LCU. Num ambiente que existe para gravar um vídeo, é desperdício puro.

### A solução: `group.name`

O AWS Load Balancer Controller permite que vários recursos `Ingress` compartilhem o mesmo `alb.ingress.kubernetes.io/group.name`. Ele **funde as regras de todos num único ALB**, e o `group.order` define a ordem de avaliação.

Isso resolve a tensão: cada serviço declara as rotas que lhe pertencem, e o resultado na AWS é um load balancer só.

```yaml
# charts/base/templates/ingress.yaml
annotations:
  alb.ingress.kubernetes.io/group.name: {{ .Values.ingress.groupName }}
  alb.ingress.kubernetes.io/group.order: {{ .Values.ingress.groupOrder | quote }}
  alb.ingress.kubernetes.io/healthcheck-path: {{ .Values.ingress.healthcheckPath | default .Values.readinessProbe.path }}
```

O `healthcheck-path` cai por padrão no `readinessProbe.path`, já definido em todo `values-prod.yaml`. Uma informação, um lugar.

### Como ficou distribuído

| serviço | rotas | `group.order` |
|---|---|---|
| `auth-service` | `/validate`, `/admin` | 10 |
| `flag-service` | `/flags` | 20 |
| `targeting-service` | `/rules` | 30 |
| `evaluation-service` | `/evaluate` | 40 |
| `analytics-service` | — | `ingress.enabled: false` |

O `analytics-service` não é exposto de propósito: ele consome fila SQS e não atende tráfego externo. O manifesto original também não o incluía.

O bloco em cada `values-prod.yaml` ficou mínimo, porque tudo que é comum vive no `values.yaml` do chart:

```yaml
ingress:
  enabled: true
  groupOrder: "20"
  paths:
    - path: /flags
```

---

## Desafio 2 — o `envFrom` que quebraria todos os deployments

### Como apareceu

A validação não parou no `helm template`. Renderizar prova que o Helm gera YAML; não prova que o Kubernetes aceita. Por isso o passo seguinte foi:

```bash
kubectl apply --dry-run=server -f <renderizado>
```

O `--dry-run=server` envia o manifesto para a API real, que aplica validação de schema e admission — sem persistir nada.

**Quatro dos cinco falharam:**

```
Deployment in version "v1" cannot be handled as a Deployment:
strict decoding error: unknown field "spec.template.spec.containers[0].envFrom[0].name"
```

### A causa

```yaml
# charts/base/templates/deployment.yaml — antes
envFrom:
  {{- if .Values.configMap.enabled }}
  - configMapRef:
      name: {{ ... }}          ← indentação correta
  {{- end }}
  {{- if or .Values.secret.enabled .Values.externalSecret.enabled }}
  - secretRef:
    name: {{ ... }}            ← um nível acima
  {{- end }}
```

Renderizava assim:

```yaml
envFrom:
  - secretRef:
    name: auth-service-secret
```

Em YAML isso não é `secretRef` com um campo `name` dentro. É um mapa com **duas chaves irmãs**: `secretRef: null` e `name: auth-service-secret`. Daí o erro apontar `envFrom[0].name` como campo desconhecido — porque no nível do item, `name` realmente não existe.

O `configMapRef` logo acima estava correto. A diferença de duas colunas passou despercebida em revisão.

### Por que o `analytics-service` passava

Ele é o único que não usa `ExternalSecret` — pega tudo de `ConfigMap` e variáveis de ambiente. O bloco defeituoso é condicional, então nunca era renderizado para ele.

Um único serviço passando é o pior cenário possível: dá a impressão de que o chart funciona.

### Correção

```diff
   - secretRef:
-    name: {{ include "togglemaster-base.secretName" . }}
+      name: {{ include "togglemaster-base.secretName" . }}
```

Duas colunas. **Sem isso, nenhum dos quatro serviços com segredo teria subido** — e o sintoma no cluster seria a `Application` em `SyncFailed` com uma mensagem sobre campo desconhecido, bem longe de "o chart tem um erro de indentação".

---

## Resumo das mudanças

| ação | arquivo | motivo |
|---|---|---|
| criado | `charts/base/templates/ingress.yaml` | não havia template de Ingress |
| editado | `charts/base/values.yaml` | bloco `ingress` com `enabled: false` por padrão |
| corrigido | `charts/base/templates/deployment.yaml` | indentação do `secretRef` no `envFrom` |
| editado | `apps/{auth,flag,targeting,evaluation}-service/values-prod.yaml` | rotas e `group.order` de cada serviço |

O `apps/analytics-service/values-prod.yaml` não foi tocado — o `ingress.enabled` já é `false` por padrão.

---

## Validação

### Renderização

`helm template` nos cinco serviços, com o `values-prod.yaml` de cada:

| serviço | recursos gerados |
|---|---|
| `auth-service` | ServiceAccount, Service, Deployment, **Ingress**, ExternalSecret |
| `flag-service` | ServiceAccount, ConfigMap, Service, Deployment, **Ingress**, ExternalSecret |
| `targeting-service` | idem |
| `evaluation-service` | idem |
| `analytics-service` | ServiceAccount, ConfigMap, Service, Deployment, HPA — **sem Ingress** |

### Contra a API do cluster

```
auth-service         ok — 5 recursos validados
flag-service         ok — 6 recursos validados
targeting-service    ok — 6 recursos validados
evaluation-service   ok — 6 recursos validados
analytics-service    ok — 5 recursos validados
```

Foi esse passo que encontrou o `envFrom`. **Renderizar não é validar** — vale registrar isso como método, não como detalhe deste caso.

---

## O que falta, levantado na comparação com o `togglemaster-platform`

Com o Ingress no lugar, o `k8s/` do `togglemaster-platform` foi comparado item a item com o que o chart produz. Quatro lacunas, em ordem de gravidade.

### 1. Migrations — bloqueia a aplicação inteira

```
k8s/migrations/auth.sql        CREATE TABLE api_keys ...
k8s/migrations/flags.sql
k8s/migrations/targeting.sql
```

**Nada neste repositório executa esses arquivos.** Os bancos RDS foram provisionados vazios.

O efeito é enganoso: os pods sobem saudáveis, o `/health` responde `200` — porque nenhum dos três serviços consulta tabela nesse endpoint — e o primeiro request de verdade falha com `relation "api_keys" does not exist`.

Saída provável: um `Job` no chart com `argocd.argoproj.io/hook: PreSync`, que roda antes do deployment e tem acesso ao RDS de dentro do cluster.

### 2. ServiceAccount sem anotação de IRSA — bloqueia dois serviços

O manifesto original anota a role:

```yaml
annotations:
  eks.amazonaws.com/role-arn: "arn:aws:iam::762103020993:role/role-eks-togglemaster-apps"
```

O `charts/base/templates/serviceaccount.yaml` **não tem campo de annotations**. A role existe na conta — foi verificado.

Sem ela, o `analytics-service` não lê o SQS nem grava no DynamoDB, e o `evaluation-service` não publica no SQS. Os dois sobem e falham em laço, exatamente o comportamento descrito no `03-lint-ruff.md` do `analytics-service`.

### 3. KEDA `ScaledObject` — recurso instalado e não usado

```yaml
kind: TriggerAuthentication   # podIdentity: aws
kind: ScaledObject            # aws-sqs-queue, minReplicaCount: 0, maxReplicaCount: 15
```

O KEDA **está instalado** no cluster pelo stage `addons`. O chart não tem template, então o `analytics-service` roda com réplica fixa em vez de escalar pela profundidade da fila — e perde o *scale to zero*.

Escalar por fila é demonstração forte, e a infraestrutura já está paga.

### 4. Um `ExternalSecret` por serviço

O chart suporta um único bloco `externalSecret`. Hoje isso basta — o `evaluation-service` precisa só do `SERVICE_API_KEY`, e é o que o `values-prod.yaml` declara.

Não é lacuna atual, mas é limite conhecido: um serviço que precise de credencial de RDS **e** de aplicação não cabe no formato.

### O que já está coberto

| manifesto do `platform` | situação no GitOps |
|---|---|
| `namespace.yaml` | Argo CD cria via `CreateNamespace=true` |
| `cluster-secret-store.yaml` | criado pelo Terraform; `Valid`/`Ready` no cluster |
| `karpenter/` | gerenciado pelo stage `addons` |
| `configmap`, `service`, `hpa`, `deployment` | têm template no chart |

---

## Pendências que seguem abertas

Além das quatro acima, permanece o registrado em [03](03-argocd-app-of-apps.md):

**`imagePullSecrets: ecr-registry-secret`.** Os `values-prod.yaml` referenciam um secret inexistente no cluster. O pull do ECR costuma funcionar pela role do nó, mas o Kubernetes registrará evento de secret ausente.

**A validação de ponta a ponta ainda não aconteceu.** O `--dry-run=server` prova que a API aceita os manifestos. Não prova que os pods ficam `Ready`, que os `ExternalSecret` sincronizam nem que os serviços conectam no RDS. Isso só é observável depois do merge na `main`.
