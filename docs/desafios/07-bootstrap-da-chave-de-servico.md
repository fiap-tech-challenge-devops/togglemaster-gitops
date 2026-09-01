# Fase 3 — Bootstrap da chave de serviço e rollout em mudança de config

**Projeto:** ToggleMaster (FIAP — Fase 3)
**Escopo:** Semeadura da `SERVICE_API_KEY`, anotação de checksum e `replicas` sob autoscaler

---

## Visão geral

Com quatro dos cinco serviços saudáveis, o primeiro teste de **tráfego real pelo ALB** encontrou o último bloqueio — e, no caminho, confirmou dois problemas estruturais do chart que já eram suspeita.

O teste percorreu o fluxo inteiro: emitir chave de API, criar flag, criar regra de targeting, avaliar. As quatro primeiras etapas passaram. A quinta devolveu `502`.

---

## O que o teste provou funcionar

| requisição | resultado |
|---|---|
| `POST /admin/keys` | `201` — auth-service grava no RDS |
| `GET /validate` | `200` — lê de volta |
| `POST /flags` | `201` — flag-service no RDS |
| `POST /rules` | `201` — targeting-service no RDS |
| `GET /evaluate` | **`502`** |

Também confirmou o desenho do Ingress: os quatro `Ingress` foram fundidos em **um único ALB** pelo `group.name`, como projetado em [04](04-ingress-e-lacunas-do-chart.md).

E o KEDA: `ScaledObject READY: True`, com o Deployment do `analytics-service` em **0 réplicas** — *scale to zero* funcionando, porque a fila estava vazia.

---

## Desafio 1 — a `SERVICE_API_KEY` era literalmente `"placeholder"`

### O sintoma

```
GET /evaluate → 502 {"error": "Erro interno ao avaliar a flag"}
```

Log do `evaluation-service`:

```
Cache MISS para flag 'enable-new-dashboard'
Erro ao avaliar flag 'enable-new-dashboard': flag-service retornou status 401
```

O serviço estava saudável, recebeu a requisição, tentou buscar os dados — e o `flag-service` recusou a autenticação.

### A causa

O `evaluation-service` chama os outros dois com `SERVICE_API_KEY`, vinda do `ExternalSecret`. O valor no Secrets Manager:

```
SERVICE_API_KEY = "placeholder"   (11 caracteres)
```

E o `infra/secrets.tf` explicava por quê:

```hcl
description   = "SERVICE_API_KEY do evaluation-service (valor emitido fora do Terraform)"
secret_string = jsonencode({ SERVICE_API_KEY = "placeholder" })

lifecycle {
  ignore_changes = [secret_string]
}
```

**Não era defeito, era bootstrap.** A chave só pode ser emitida pelo `auth-service`, que precisa estar rodando — o Terraform não tem como criá-la. Por isso o placeholder e o `ignore_changes`: o Terraform criava o compartimento e saía do caminho para alguém preencher.

Esse alguém nunca preencheu, e nada no sistema avisava.

### As duas descobertas que permitiram automatizar

**O prefixo `tm_key_` é decoração.** O [`handlers.go`](https://github.com/fiap-tech-challenge-devops/auth-service) valida assim:

```go
keyHash := hashAPIKey(keyString)
err := a.DB.QueryRow("SELECT id FROM api_keys WHERE key_hash = $1 AND is_active = true", keyHash).Scan(&id)
```

Nada verifica o formato. Qualquer string vale, desde que o SHA-256 dela esteja na tabela.

**O `sha256sum` do Alpine produz o mesmo digest do `crypto/sha256` do Go.** Verificado com a mesma string nos dois runtimes:

```
alpine sha256sum:  4cd7289cabf3480ffee734797099adcd15eb8b6458adfb89e2432f4d86b0554f
go crypto/sha256:  4cd7289cabf3480ffee734797099adcd15eb8b6458adfb89e2432f4d86b0554f
```

Isso vale checar em vez de assumir: se o Go usasse algum salt ou codificação diferente, toda a abordagem cairia.

### Correção

**No Terraform** — o valor passa a ser gerado, e o `ignore_changes` sai porque não há mais preenchimento manual a proteger:

```hcl
resource "random_password" "service_api_key" {
  length  = 48
  special = false
}

secret_string = jsonencode({ SERVICE_API_KEY = "tm_key_${random_password.service_api_key.result}" })
```

**No chart** — o Job de migration do `auth-service`, que já tem acesso ao banco, semeia o hash:

```sh
HASH=$(printf '%s' "$SERVICE_API_KEY" | sha256sum | cut -d' ' -f1)
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 \
  -c "INSERT INTO api_keys (name, key_hash) VALUES ('evaluation-service', '$HASH') ON CONFLICT (key_hash) DO NOTHING;"
```

Controlado por valores, então cada serviço decide se usa:

```yaml
migration:
  seedApiKeys:
    - name: evaluation-service
      keyEnv: SERVICE_API_KEY
```

O `ON CONFLICT (key_hash) DO NOTHING` garante idempotência — a coluna já era `UNIQUE`, e o Job é hook de `Sync`, então roda a cada sincronização.

### As alternativas consideradas

| abordagem | por que não |
|---|---|
| Job `PostSync` chamando `POST /admin/keys` | mais fiel ao fluxo real, mas precisa de `secretsmanager:PutSecretValue`, de lógica de idempotência própria — senão gera chave nova a cada sync e acumula órfãs — e de ordenação com o `auth-service` pronto |
| `auth-service` semear a si mesmo no boot | mais elegante, elimina a circularidade de vez, mas exige mudança de código de aplicação |
| deixar manual | dois comandos por ambiente; como o ambiente sobe e desce para gravar, é o passo que se esquece na hora errada |

A escolha tem um custo honesto: **o Job de migration passa a conhecer um segredo de outro serviço.** É aceitável porque esse Job já lê a `DATABASE_URL` do banco de autenticação — ele é o componente mais privilegiado do conjunto, e semear credencial de bootstrap é função clássica de migration.

Consequência lateral: como o Job compartilha o secret com a aplicação, os pods do `auth-service` também passam a receber `SERVICE_API_KEY` no ambiente, sem usá-la.

---

## Desafio 2 — mudar ConfigMap não reinicia pod

### Como apareceu

Depois do merge que corrigiu o `REDIS_URL` ([06](06-primeiro-sync-real.md)), o ConfigMap no cluster **já tinha a URL correta** — e os pods continuavam em `CrashLoopBackOff` com a URL vazia.

A razão é característica do Kubernetes: os valores de `envFrom` são resolvidos **quando o container é criado**. O Argo CD atualizou o ConfigMap, o `spec` do Deployment não mudou, nada disparou rollout, e os pods seguiram com as variáveis antigas em memória.

Eles se recuperaram por acidente: estavam em `CrashLoopBackOff`, e o reinício seguinte criou o container de novo, lendo o ConfigMap atualizado.

**Se os pods estivessem saudáveis com uma configuração defasada, ficariam defasados indefinidamente** — e nada indicaria isso.

### Um detalhe do diagnóstico

Durante a investigação foi executado um `kubectl rollout restart`. Ele criou um ReplicaSet novo que **ficou zerado**, e a anotação `restartedAt` desapareceu do Deployment.

O motivo é o `selfHeal: true` das `Application`: um campo que não está no Git é revertido. Ou seja, o restart manual foi desfeito, e quem consertou foi o backoff natural do CrashLoop. Vale registrar porque a sequência dá a impressão contrária.

### Correção

```yaml
template:
  metadata:
    annotations:
      checksum/config: {{ toYaml .Values.configMapData | sha256sum }}
```

Quando o conteúdo do ConfigMap muda, o hash muda, o `spec.template` muda, e o Kubernetes faz rollout — porque agora o Deployment de fato mudou. Resolve dentro do GitOps, sem comando manual.

### O que isso não cobre

O valor de um `ExternalSecret` vive **fora** do repositório. O Helm não o enxerga, então não há como incluí-lo num checksum.

Se a `SERVICE_API_KEY` for rotacionada depois, o Secret do Kubernetes é atualizado pelo operador e os pods seguem com o valor antigo — exatamente o problema deste desafio, sem a mesma solução.

Não é bloqueio hoje: num ambiente novo, o Terraform gera a chave **antes** de o cluster sincronizar, então o valor certo chega desde o primeiro pod. Fica registrado como limite conhecido.

---

## Desafio 3 — `replicas` contra o autoscaler

### O sintoma

```
analytics-service   OutOfSync   Healthy
Deployment/analytics-service  sync=OutOfSync  health=Healthy
```

O `analytics-service` estava funcionando corretamente — o KEDA levou o Deployment a 0 réplicas porque a fila estava vazia, que é o comportamento desejado.

Mas o Git diz `replicaCount: 2`. O Argo CD compara e vê divergência. Com `selfHeal: true`, ele tenta voltar para 2 e o KEDA derruba de novo, indefinidamente.

### Correção

O chart passa a omitir o campo quando há autoscaler:

```yaml
spec:
  {{- if not (or .Values.autoscaling.enabled .Values.keda.enabled) }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
```

Sem o campo no manifesto, não há divergência a detectar. É o padrão que os charts oficiais do Helm adotam, pelo mesmo motivo.

---

## Resumo das mudanças

### `togglemaster-iac` — branch `feat/service-api-key-automatica`

| arquivo | mudança |
|---|---|
| `infra/secrets.tf` | `random_password.service_api_key`; remove o `"placeholder"` e o `ignore_changes` |

### `togglemaster-gitops` — branch `feat/bootstrap-e-rollout`

| arquivo | mudança |
|---|---|
| `charts/base/templates/migration-job.yaml` | semeadura via `seedApiKeys` |
| `charts/base/templates/deployment.yaml` | `checksum/config` e `replicas` condicional |
| `charts/base/values.yaml` | `migration.seedApiKeys: []` |
| `apps/auth-service/values-prod.yaml` | terceira entrada no `externalSecret` e `seedApiKeys` |

---

## Validação

### A semeadura foi executada de verdade

O comando foi **extraído do manifesto renderizado** — não reescrito à mão — e executado contra um PostgreSQL 16 em container, com uma chave conhecida:

```
CREATE TABLE
INSERT 0 1
```

Em seguida, o `auth-service` real subiu contra o mesmo banco:

| requisição | resultado |
|---|---|
| `GET /validate` com a chave semeada | `200` `{"message":"Chave válida"}` |
| `GET /validate` com chave errada | `401` |

O segundo caso importa tanto quanto o primeiro: prova que a semeadura não afrouxou a validação.

**Idempotência**, reexecutando o mesmo Job:

```
INSERT 0 0
total de chaves: 1
```

### Renderização

| serviço | `replicas` | `checksum/config` |
|---|---|---|
| `auth-service` | 2 | presente |
| `flag-service` | 2 | presente |
| `targeting-service` | 2 | presente |
| `evaluation-service` | 2 | presente |
| `analytics-service` | **ausente** | presente |

### Contra a API do cluster

```
auth-service         ok — 6 recursos
flag-service         ok — 7 recursos
targeting-service    ok — 7 recursos
evaluation-service   ok — 6 recursos
analytics-service    ok — 6 recursos
```

---

## O que segue pendente

**Rotação de segredo remoto não dispara rollout.** Descrito no desafio 2.

**Um `ExternalSecret` por serviço.** Limite herdado de [04](04-ingress-e-lacunas-do-chart.md). O `auth-service` contorna agregando três chaves de segredos remotos diferentes num único bloco `data`, o que funciona — mas não permite dois `target` distintos.

**`imagePullSecrets: ecr-registry-secret`** segue referenciando um secret inexistente.

**O ciclo completo ainda não foi observado passando.** Este documento prova que a chave semeada autentica em ambiente controlado. Que o `/evaluate` devolva `200` pelo ALB depende do `apply` do Terraform e do sync do Argo CD — e disso só se tem certeza executando.
