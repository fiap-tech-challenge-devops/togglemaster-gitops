# Fase 3 — O primeiro sync real no cluster

**Projeto:** ToggleMaster (FIAP — Fase 3)
**Escopo:** Deadlock de `sync-wave` no `analytics-service` e `REDIS_URL` do `evaluation-service`

---

## Visão geral

Com o merge do PR anterior, o Argo CD sincronizou pela primeira vez de verdade. **Três dos cinco serviços subiram saudáveis** e as três migrations rodaram — mas dois quebraram, por motivos sem relação entre si.

Um dos dois foi **defeito introduzido por mim** no documento [05](05-irsa-migrations-e-keda.md). O outro estava latente desde a fase 2.

Este documento registra os dois, porque nenhum apareceria em `helm template` nem em `--dry-run=server`: ambos só existem em tempo de sincronização e execução.

---

## O que funcionou

Vale registrar, porque valida o trabalho anterior:

```
auth-service-migration        Complete   1/1   11s
flag-service-migration        Complete   1/1   11s
targeting-service-migration   Complete   1/1   11s

auth-service            SecretSynced   True
evaluation-service-app  SecretSynced   True
flag-service-rds        SecretSynced   True
targeting-service-rds   SecretSynced   True
```

As migrations executaram na ordem correta — depois do segredo existir, antes do Deployment. Os `ExternalSecret` materializaram as senhas do RDS a partir do Secrets Manager. `auth-service`, `flag-service` e `targeting-service` ficaram `Running` com duas réplicas cada.

---

## Desafio 1 — impasse de `sync-wave` no `analytics-service`

### O sintoma

Na interface do Argo CD:

```
analytics-service   Degraded   OutOfSync   Sync failed
```

E no cluster, **nenhum pod do analytics**. A primeira leitura foi enganosa: com `minReplicaCount: 0` no KEDA, ausência de pods parece *scale to zero* funcionando.

Não era.

### A causa

```
ScaledObject/analytics-service   Failed
  ScaledObject doesn't have correct scaleTargetRef specification:
  deployments.apps "analytics-service" not found

Deployment/analytics-service     sync=OutOfSync   health=Missing
```

Quando o Job de migration entrou, o `Deployment` ganhou `sync-wave: "2"`. O `ScaledObject` e o `HorizontalPodAutoscaler` ficaram **sem anotação**, ou seja, na onda 0.

O resultado é circular:

| onda | o que acontece |
|---|---|
| 0 | `ScaledObject` é aplicado, aponta para um Deployment inexistente → `Degraded` |
| — | o Argo CD só avança de onda quando a atual está saudável |
| 2 | o Deployment **nunca chega a ser criado** |

O `ScaledObject` espera o Deployment. O Deployment espera a onda 0 ficar saudável. Nenhum dos dois sai do lugar, e o Argo CD tentou cinco vezes antes de desistir.

### Por que não apareceu antes

Todas as validações do documento anterior foram de **renderização** e `--dry-run=server`. As duas confirmam que o YAML é válido e que a API aceita cada recurso isoladamente.

Nenhuma delas simula a **ordem de aplicação**. O `sync-wave` é comportamento do Argo CD em tempo de sincronização — não existe fora dele.

### Correção

```diff
 kind: ScaledObject
 metadata:
   name: {{ .Release.Name }}
   namespace: {{ .Values.namespace | default "togglemaster" }}
+  annotations:
+    argocd.argoproj.io/sync-wave: "3"
```

O mesmo no `hpa.yaml`. Os dois referenciam o Deployment e precisam vir depois dele.

A ordem final do chart:

| onda | recursos |
|---|---|
| 0 | ServiceAccount, ConfigMap, Service, Ingress, ExternalSecret, TriggerAuthentication |
| 1 | ConfigMap do SQL + Job da migration |
| 2 | Deployment |
| 3 | ScaledObject, HorizontalPodAutoscaler |

### O HPA não quebrou por acaso

Os cinco serviços estão com `autoscaling.enabled: false` — o do `analytics` foi desligado no documento [05](05-irsa-migrations-e-keda.md), justamente para não conflitar com o KEDA.

Então o `hpa.yaml` nunca chegou a ser renderizado depois que o Deployment ganhou onda 2. A armadilha era idêntica e só esperava alguém ligar autoscaling em qualquer serviço.

---

## Desafio 2 — `REDIS_URL` nunca preenchida

### O sintoma

```
evaluation-service-6d86696bf7-b2tm8   0/1   CrashLoopBackOff   7 restarts
evaluation-service-6d86696bf7-nd6jf   0/1   CrashLoopBackOff   7 restarts
```

Log do container:

```
Não foi possível parsear a URL do Redis: redis: invalid URL scheme:
```

O esquema aparece vazio depois dos dois pontos porque não havia esquema nenhum.

### A causa

O ConfigMap carregava um placeholder **literal**, herdado do manifesto da fase 2:

```yaml
# togglemaster-platform/k8s/evaluation-service/configmap.yaml
REDIS_URL: "set-by-deploy-from-ssm"  # Injetado pelo stage de deploy a partir do SSM
```

O comentário descreve um estágio de deploy que leria `/togglemaster/iac/redis-url` e substituiria o valor antes de aplicar.

**No GitOps não existe esse estágio.** O Argo CD aplica o que está no repositório, literalmente. O placeholder foi para o cluster como texto, e o `redis.ParseURL` falhou.

É um caso interessante de migração: o manifesto estava "correto" no modelo antigo, onde havia um passo intermediário. Ao mover para GitOps, o passo desapareceu e o placeholder virou defeito silencioso — silencioso até o pod reiniciar em laço.

### O valor existia o tempo todo

O `infra/ssm-exports.tf` publica o parâmetro:

```hcl
resource "aws_ssm_parameter" "redis_url" {
  name  = "${local.ssm_prefix}/redis-url"
  value = "redis://${module.redis.primary_endpoint_address}:${module.redis.port}/0"
}
```

E ele está lá:

```
/togglemaster/iac/redis-url = redis://redis-togglemaster.gysclb.ng.0001.use1.cache.amazonaws.com:6379/0
```

### Um desvio no diagnóstico

Durante a investigação, `aws ssm get-parameter --name /togglemaster/iac/redis-url` retornou `ParameterNotFound`, enquanto `describe-parameters` listava o mesmo parâmetro com ARN completo.

A contradição era do ambiente, não da AWS: o Git Bash no Windows converte argumentos que começam com `/` em caminho de sistema. O nome chegava à API já corrompido. Com `MSYS_NO_PATHCONV=1` o valor veio na primeira tentativa.

Fica registrado porque a mensagem de erro apontava para o lugar errado — e quase levou à conclusão de que o IaC não estava exportando o parâmetro.

### Correção

Valor literal no `values-prod.yaml`:

```diff
-  REDIS_URL: "set-by-deploy-from-ssm"
+  REDIS_URL: "redis://redis-togglemaster.gysclb.ng.0001.use1.cache.amazonaws.com:6379/0"
```

### A alternativa, e por que não agora

O padrão do repositório para valor vindo da AWS é `ExternalSecret` — é assim que as senhas do RDS chegam. O mesmo caberia aqui.

O impedimento é concreto: o `ClusterSecretStore` instalado aponta para o **Secrets Manager**, e o parâmetro vive no **Parameter Store**. Usá-lo exigiria um segundo `SecretStore` com `provider.aws.service: ParameterStore`, e o chart hoje suporta um único bloco `externalSecret` por serviço — a lacuna que ficou aberta em [04](04-ingress-e-lacunas-do-chart.md).

O valor literal destrava agora. O endpoint só muda se o ElastiCache for destruído e recriado, o que torna o custo do atalho baixo e conhecido.

---

## Resumo das mudanças

| ação | arquivo | desafio |
|---|---|---|
| editado | `charts/base/templates/scaledobject.yaml` | 1 — `sync-wave: "3"` |
| editado | `charts/base/templates/hpa.yaml` | 1 — `sync-wave: "3"` |
| editado | `apps/evaluation-service/values-prod.yaml` | 2 — `REDIS_URL` real |

---

## Validação

Renderização dos cinco e `--dry-run=server` contra o cluster:

```
auth-service         ok — 7 recursos
flag-service         ok — 8 recursos
targeting-service    ok — 8 recursos
evaluation-service   ok — 6 recursos
analytics-service    ok — 6 recursos
```

Ordem das ondas conferida no `analytics-service` renderizado:

```
ServiceAccount        onda 0
ConfigMap             onda 0
Service               onda 0
TriggerAuthentication onda 0
Deployment            onda 2
ScaledObject          onda 3
```

E as variáveis que o `evaluation-service` passa a receber:

```
AWS_REGION             us-east-1
AWS_SQS_URL            https://sqs.us-east-1.amazonaws.com/762103020993/togglemaster-evaluation-events
FLAG_SERVICE_URL       http://flag-service:8002
TARGETING_SERVICE_URL  http://targeting-service:8003
REDIS_URL              redis://redis-togglemaster.gysclb.ng.0001.use1.cache.amazonaws.com:6379/0
```

Mais `PORT` e `APP_ENV` como env diretas, e `SERVICE_API_KEY` vindo do `ExternalSecret`.

**A validação real é o próximo sync.** Como este documento demonstra, renderizar e validar contra a API não cobre ordem de aplicação nem execução.

---

## Lição que vale além deste caso

As duas falhas têm a mesma natureza: **só existem em tempo de execução**.

| verificação | pega |
|---|---|
| `helm template` | erro de sintaxe do chart |
| `kubectl apply --dry-run=server` | schema inválido, campo desconhecido, CRD ausente |
| **sync real** | ordem entre recursos, valor de configuração errado, dependência externa |

O documento [04](04-ingress-e-lacunas-do-chart.md) já registrava que *"renderizar não é validar"*. Este acrescenta o degrau seguinte: **validar não é executar**.

---

## O que segue pendente

**`SecretStore` do Parameter Store**, para o `REDIS_URL` sair do Git.

**Mais de um `ExternalSecret` por serviço**, que é o que destrava o item acima.

**`imagePullSecrets: ecr-registry-secret`**, ainda referenciando um secret inexistente. Não impediu os pods de subir — o pull do ECR funciona pela role do nó, como se esperava — mas continua gerando evento de secret ausente.

**Nenhum tráfego real passou pelos serviços ainda.** Os pods estão `Running`, o que significa que o `/health` responde. Não significa que o `auth-service` autentica contra o RDS, nem que o `evaluation-service` fecha o ciclo com Redis e SQS.
