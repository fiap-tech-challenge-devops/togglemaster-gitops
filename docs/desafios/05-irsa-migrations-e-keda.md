# Fase 3 — IRSA, migrations e KEDA

**Projeto:** ToggleMaster (FIAP — Fase 3)
**Escopo:** As três lacunas levantadas em [04](04-ingress-e-lacunas-do-chart.md)

---

## Visão geral

O documento anterior terminou com quatro lacunas entre o `togglemaster-platform/k8s/` e o que o `charts/base` produzia. Três foram fechadas aqui.

Nenhuma delas exigiu mudança no `togglemaster-iac`: a infraestrutura já estava provisionada, e o que faltava era o chart saber usá-la.

---

## Desafio 1 — ServiceAccount sem anotação de IRSA

### O problema

O `charts/base/templates/serviceaccount.yaml` criava o ServiceAccount sem campo de `annotations`. No EKS, a associação entre um ServiceAccount e uma role da AWS é feita exatamente por uma anotação:

```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::762103020993:role/role-eks-togglemaster-apps
```

Sem ela, o pod não recebe credencial da AWS. O `analytics-service` não lê o SQS nem grava no DynamoDB; o `evaluation-service` não publica no SQS. Os dois sobem e falham em laço — comportamento idêntico ao que o `03-lint-ruff.md` do `analytics-service` documenta.

### O que não precisou mudar

A suspeita inicial era que a trust policy da role precisaria listar cada ServiceAccount. O `infra/irsa.tf` mostrou o contrário:

```hcl
module "irsa_apps" {
  name             = "role-eks-${var.system}-apps"
  namespace        = var.app_namespace     # togglemaster
  service_accounts = ["*"]
}
```

O `["*"]` faz a role confiar em **qualquer** ServiceAccount do namespace `togglemaster`. Anotar basta.

Foi verificado também que os ServiceAccounts dos operadores já vêm anotados pelo Helm do stage `addons`:

```
keda-operator      → role-eks-togglemaster-keda
external-secrets   → role-eks-togglemaster-external-secrets
```

### Correção

```yaml
# charts/base/templates/serviceaccount.yaml
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

Anotados apenas `analytics-service` e `evaluation-service`. Os outros três não acessam a AWS diretamente — quem lê o Secrets Manager é o operador do external-secrets, com a própria role.

Confirmado que o `deployment.yaml` já fazia `serviceAccountName: {{ include ... }}`; sem isso a anotação não teria efeito.

---

## Desafio 2 — KEDA instalado e sem uso

### O problema

O stage `addons` instala o KEDA, e a role `role-eks-togglemaster-keda` já tem `sqs:GetQueueAttributes`. Mas o chart não tinha template, então o `analytics-service` rodava com réplica fixa em vez de escalar pela profundidade da fila — e perdia o *scale to zero*.

### Como a autenticação funciona aqui

O `TriggerAuthentication` usa `identityOwner: operator`:

```yaml
spec:
  podIdentity:
    provider: aws
```

Isso significa que **quem consulta a fila é o `keda-operator`**, não a aplicação. O operador tem a própria role, com permissão mínima — só `GetQueueAttributes`. A aplicação nunca precisa de credencial para ser escalada.

É uma separação limpa: quem decide escalar e quem consome a fila são identidades diferentes, com permissões diferentes.

### O conflito que apareceu na renderização

A primeira renderização produziu **HPA e ScaledObject apontando para o mesmo Deployment**:

```
ServiceAccount, ConfigMap, Service, Deployment, HorizontalPodAutoscaler, ScaledObject, TriggerAuthentication
```

O KEDA cria o próprio HPA por baixo. Dois controladores escalando o mesmo Deployment disputam o campo `replicas`, cada um revertendo o outro.

O `values-prod.yaml` do `analytics-service` tinha `autoscaling.enabled: true`. O manifesto original do `togglemaster-platform` **não** tem `hpa.yaml` para esse serviço — só `scaledobject.yaml`. Ou seja, o valor no GitOps já divergia do desenho.

### Correção

Template novo com `ScaledObject` + `TriggerAuthentication`, e `autoscaling.enabled: false` no `analytics-service`.

```yaml
keda:
  enabled: true
  queueURL: "https://sqs.us-east-1.amazonaws.com/762103020993/togglemaster-evaluation-events"
  queueLength: "500"
  minReplicaCount: 0
  maxReplicaCount: 15
```

A URL da fila foi obtida da conta com `aws sqs get-queue-url`, não copiada do manifesto antigo.

---

## Desafio 3 — as migrations

### O problema

```
togglemaster-platform/k8s/migrations/auth.sql
togglemaster-platform/k8s/migrations/flags.sql
togglemaster-platform/k8s/migrations/targeting.sql
```

Nada neste repositório executava esses arquivos. Os bancos RDS foram provisionados vazios.

O efeito é o mais traiçoeiro do conjunto: **os pods sobem saudáveis e o `/health` responde `200`**, porque nenhum dos três serviços consulta tabela nesse endpoint. Só o primeiro request de verdade falha, com `relation "api_keys" does not exist`.

Quem olhasse apenas `kubectl get pods` concluiria que funcionou.

### Onde o SQL deveria morar

O `.Files.Get` do Helm só lê arquivos **dentro do diretório do chart**. O SQL é diferente por serviço, então manter os arquivos separados exigiria colocá-los em `apps/<serviço>/` — fora do alcance do template.

| opção | avaliação |
|---|---|
| `.sql` em `charts/base/` | um arquivo por serviço dentro de um chart compartilhado; não escala |
| Job avulso em `applications/` | manifesto solto, fora do modelo do chart |
| **SQL inline no `values-prod.yaml`** | tudo versionado junto do serviço a que pertence |

A terceira foi escolhida. O `values-prod.yaml` cresce, mas o SQL fica ao lado da imagem e das variáveis do mesmo serviço.

### A ordem importa

Um Job de migration precisa rodar **depois** do segredo com a `DATABASE_URL` existir e **antes** do Deployment subir. Isso é resolvido com `sync-wave`:

| onda | recursos |
|---|---|
| 0 | ServiceAccount, ConfigMap, Service, ExternalSecret |
| 1 | ConfigMap do SQL + Job da migration |
| 2 | Deployment |

O Argo CD só avança de onda quando a anterior está saudável. Sem isso, os pods poderiam subir antes das tabelas existirem — voltando ao problema original por outro caminho.

O Job é `hook: Sync` com `hook-delete-policy: BeforeHookCreation`: reexecuta a cada sincronização e apaga a execução anterior, em vez de acumular objetos `Job` no namespace.

### Um erro no caminho

A primeira versão do template passava a URI por variável de ambiente:

```yaml
env:
  - name: PGURI
    valueFrom:
      secretKeyRef: ...
command: ["psql"]
```

**`PGURI` não existe.** O `libpq` lê `PGHOST`, `PGUSER`, `PGPASSWORD` e afins, mas não uma variável com a URI inteira. O `psql` teria tentado conectar no socket local e falhado.

A forma correta é passar a URI como argumento:

```yaml
command: ["sh", "-c"]
args:
  - psql "$DATABASE_URL" --set ON_ERROR_STOP=1 -f /sql/migration.sql
```

O `ON_ERROR_STOP=1` importa: sem ele o `psql` segue depois de um erro e sai com código zero, e o Job passaria com o schema pela metade.

---

## Resumo das mudanças

| ação | arquivo | desafio |
|---|---|---|
| editado | `charts/base/templates/serviceaccount.yaml` | 1 — bloco `annotations` |
| criado | `charts/base/templates/scaledobject.yaml` | 2 — `ScaledObject` + `TriggerAuthentication` |
| criado | `charts/base/templates/migration-job.yaml` | 3 — ConfigMap + Job |
| editado | `charts/base/templates/deployment.yaml` | 3 — `sync-wave: "2"` |
| editado | `charts/base/values.yaml` | blocos `serviceAccount.annotations`, `keda`, `migration` |
| editado | `apps/analytics-service/values-prod.yaml` | IRSA, KEDA, `autoscaling: false` |
| editado | `apps/evaluation-service/values-prod.yaml` | IRSA |
| editado | `apps/{auth,flag,targeting}-service/values-prod.yaml` | SQL inline |

Todos os blocos novos nascem desligados no `values.yaml` do chart (`enabled: false`), então nenhum serviço ganha comportamento sem pedir.

---

## Validação

### Renderização

| serviço | recursos |
|---|---|
| `auth-service` | ServiceAccount, ConfigMap, Service, Deployment, **Job**, Ingress, ExternalSecret |
| `flag-service` | + ConfigMap de app | 
| `targeting-service` | idem |
| `evaluation-service` | ServiceAccount, ConfigMap, Service, Deployment, Ingress, ExternalSecret |
| `analytics-service` | ServiceAccount, ConfigMap, Service, Deployment, **ScaledObject**, **TriggerAuthentication** |

O `analytics-service` deixou de renderizar HPA, como esperado.

### O SQL foi executado de verdade

Renderizar o ConfigMap não prova que o SQL é válido. O conteúdo foi **extraído do manifesto renderizado** e executado contra um PostgreSQL 16 em container, com o mesmo comando do Job:

```bash
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 -f /sql/<serviço>.sql
```

Resultado:

```
 public | api_keys        | table
 public | flags           | table
 public | targeting_rules | table

 set_timestamp | flags
 set_timestamp | targeting_rules
```

As três tabelas e as duas triggers. Isso também confirmou que o `$$` do *dollar quoting* das funções PL/pgSQL sobrevive ao aninhamento em bloco YAML dentro do ConfigMap — a dúvida mais concreta dessa abordagem.

**Idempotência:** o mesmo arquivo foi reexecutado e saiu limpo. Todo o DDL usa `IF NOT EXISTS` ou `OR REPLACE`, e o `DROP TRIGGER IF EXISTS` antes do `CREATE TRIGGER` cobre o único objeto que não aceita `OR REPLACE`. Isso importa porque o hook `Sync` roda a cada sincronização.

### Contra a API do cluster

```
auth-service         ok — 7 recursos
flag-service         ok — 8 recursos
targeting-service    ok — 8 recursos
evaluation-service   ok — 6 recursos
analytics-service    ok — 6 recursos
```

Os CRDs do KEDA (`scaledobject.keda.sh`, `triggerauthentication.keda.sh`) foram aceitos, o que confirma que o operador está instalado e as versões de API batem.

---

## O que segue pendente

**O quarto item do [04](04-ingress-e-lacunas-do-chart.md) não foi endereçado:** o chart suporta um único bloco `externalSecret` por serviço. Hoje basta, mas um serviço que precise de credencial de RDS **e** de aplicação não cabe no formato.

**`imagePullSecrets: ecr-registry-secret`.** Os `values-prod.yaml` seguem referenciando um secret inexistente no cluster.

**Nada disso foi observado rodando.** Todas as validações aqui são de renderização, execução isolada do SQL e `--dry-run=server`. Que os pods fiquem `Ready`, que os `ExternalSecret` sincronizem, que o Job conecte no RDS e que o KEDA escale de fato — só depois do merge na `main`.
