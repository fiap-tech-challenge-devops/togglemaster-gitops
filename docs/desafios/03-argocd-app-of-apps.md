# Fase 3 — O app-of-apps não sincronizava

**Projeto:** ToggleMaster (FIAP — Fase 3)
**Escopo:** Layout de `applications/`, remoção do `kustomization.yaml` e do `app-of-apps.yaml`

---

## Visão geral

Com a infraestrutura provisionada e o Argo CD instalado, **nenhum pod subiu**. O namespace `togglemaster` permanecia vazio.

A causa não era permissão de repositório, credencial nem rede: era uma restrição de segurança do `kustomize`, disparada pelo layout dos arquivos neste repositório.

Este documento registra o diagnóstico, a correção e a validação — incluindo um segundo problema que **parecia** existir e não existia.

---

## O sintoma

```
$ kubectl get applications -n argocd
NAME   SYNC STATUS   HEALTH STATUS
root   Unknown       Healthy
```

`Unknown` é fácil de ler errado. Não significa "sincronizando" nem "ainda não avaliado" — significa que o Argo CD **não conseguiu determinar** o estado desejado, porque falhou ao renderizar o repositório.

O `Healthy` ao lado engana ainda mais: ele descreve a saúde dos recursos que a `Application` gerencia. Como ela não gerencia nenhum, não há nada doente.

Só uma `Application`, e nenhuma das cinco dos serviços. Elas nunca chegaram a ser criadas.

---

## A causa

O erro completo está em `status.conditions`:

```
[ComparisonError] Failed to load target state: failed to generate manifest:
`kustomize build <cached>/applications` failed exit status 1:
Error: accumulating resources:
  accumulation err='accumulating resources from '../argocd/auth-service.yaml':
  security; file '<cached>/argocd/auth-service.yaml' is not in or below '<cached>/applications''
```

A palavra que importa é **`security`**.

### O layout que causava isso

```
applications/
└── kustomization.yaml        ← apontava para fora do próprio diretório
argocd/
├── app-of-apps.yaml
├── auth-service.yaml
├── flag-service.yaml
├── targeting-service.yaml
├── evaluation-service.yaml
└── analytics-service.yaml
```

```yaml
# applications/kustomization.yaml
resources:
  - ../argocd/auth-service.yaml
  - ../argocd/flag-service.yaml
  ...
```

O `root`, criado pelo Terraform, aponta para `path: applications`. O Argo CD detecta o `kustomization.yaml` e chama `kustomize build` naquele diretório.

O `kustomize` **recusa por projeto** carregar arquivo fora da raiz da build. É proteção contra path traversal: sem ela, um `kustomization.yaml` poderia ler qualquer arquivo do sistema onde o renderizador roda.

Não existe flag no Argo CD que contorne isso. A restrição é do `kustomize`, e é deliberada.

### Por que passou despercebido

Nada quebra em tempo de commit. O YAML é válido, o repositório está consistente, o CD promoveu as imagens normalmente — os `values-prod.yaml` já tinham os SHAs corretos.

A falha só aparece quando o Argo CD tenta renderizar, e o sintoma que ela produz (`Unknown` + `Healthy`) não se parece com erro.

---

## Desafio 1 — o `kustomization.yaml` não tinha função

Olhando o que ele fazia, a resposta ficou simples: **agregava cinco arquivos**. Nada mais — sem `patches`, sem `namePrefix`, sem `configMapGenerator`.

E o Argo CD lê um diretório de YAML nativamente. Aponte `path` para uma pasta e ele aplica todos os manifestos que encontrar.

O `kustomize` estava ali sem entregar nada, e trazendo junto uma restrição que quebrou o repositório inteiro.

### Correção

Mover as cinco `Application` para dentro de `applications/` e apagar o `kustomization.yaml`:

```
applications/
├── analytics-service.yaml
├── auth-service.yaml
├── evaluation-service.yaml
├── flag-service.yaml
└── targeting-service.yaml
```

Sem arquivo fora do diretório, sem `kustomize`, sem restrição de segurança para violar.

---

## Desafio 2 — o `app-of-apps.yaml` duplicava o `root`

O `argocd/app-of-apps.yaml` definia uma `Application` chamada `togglemaster-apps`, apontando para o mesmo `path: applications`, com `syncPolicy.automated` e `prune: true`.

Mas o app-of-apps **já existe**, criado pelo Terraform no stage `addons`:

```hcl
# togglemaster-iac/addons/argocd.tf
resource "helm_release" "argocd_apps" {
  chart = "argocd-apps"
  values = [yamlencode({ applications = { root = { ... } } })]
}
```

Se o `togglemaster-apps` fosse aplicado, dois app-of-apps gerenciariam os mesmos cinco recursos, ambos com `prune: true`. O resultado seria disputa: cada um enxergaria os recursos do outro como órfãos.

Depois da correção do desafio 1, o arquivo seria carregado automaticamente — porque o Argo CD passa a ler o diretório inteiro. Ou seja: a correção do primeiro problema **ativaria** o segundo.

### Correção

Removido. O `root` provisionado pelo Terraform é o único app-of-apps.

A escolha de manter o do Terraform e não o do repositório tem razão: quem cria o Argo CD é o `addons`, então ele precisa criar também o ponto de entrada — senão o cluster sobe sem nada apontando para este repositório, e alguém teria que aplicar um manifesto à mão. Isso contradiz o princípio declarado no README: *"se não está neste repositório, não deveria estar rodando"* — mas a exceção é o próprio gancho que faz o GitOps começar.

---

## O problema que parecia existir e não existia

Cada `Application` de serviço usa um `values` fora do diretório do chart:

```yaml
source:
  path: charts/base
  helm:
    valueFiles:
      - ../../apps/auth-service/values-prod.yaml
```

É **o mesmo padrão** que quebrou o `kustomize`: arquivo fora do `path`. A suspeita natural era que o Argo CD recusaria também, e que a correção do desafio 1 apenas revelaria a próxima falha.

### Como foi verificado

Em vez de supor, uma `Application` de diagnóstico foi criada apontando para a branch de correção, **sem `syncPolicy.automated`** — assim ela compara manifestos e reporta erro, sem implantar nada:

```yaml
metadata:
  name: zz-diagnostico-valuefiles
spec:
  source:
    targetRevision: fix/argocd-app-of-apps
    path: charts/base
    helm:
      valueFiles:
        - ../../apps/auth-service/values-prod.yaml
  # sem syncPolicy
```

Resultado:

```
sync:   OutOfSync
health: Missing

recursos renderizados:
  Service/zz-diagnostico-valuefiles
  ServiceAccount/auth-service
  Deployment/zz-diagnostico-valuefiles
  ExternalSecret/auth-service
```

**Nenhum `ComparisonError`.** O `OutOfSync` significa apenas que os recursos ainda não existem no cluster — que é o esperado, já que não havia sync automático.

O Argo CD **renderizou o chart com sucesso**, resolvendo o `valueFiles` fora do `path`. A restrição do `kustomize` não se aplica ao Helm no Argo CD.

A `Application` de diagnóstico foi removida em seguida, e o namespace `togglemaster` seguiu vazio.

### O que isso ensinou sobre o chart

Os nomes `Service/zz-diagnostico-valuefiles` e `Deployment/zz-diagnostico-valuefiles` mostram que o `charts/base` nomeia recursos pelo **nome da release**, ou seja, pelo nome da `Application`. Com as `Application` reais (`auth-service`, `flag-service`…), os recursos saem com o nome certo.

O `ServiceAccount` e o `ExternalSecret`, que vêm de campos explícitos do `values`, já saíram corretos no diagnóstico.

---

## Resumo das mudanças

| ação | arquivo | motivo |
|---|---|---|
| movido | `argocd/{auth,flag,targeting,evaluation,analytics}-service.yaml` → `applications/` | tirar os manifestos de fora do `path` do `root` |
| removido | `applications/kustomization.yaml` | só agregava arquivos; o Argo CD lê diretório nativamente |
| removido | `argocd/app-of-apps.yaml` | duplicava o `root` criado pelo Terraform |

O diretório `argocd/` deixou de existir.

**Nenhum chart, `values-prod.yaml` ou tag de imagem foi alterado.**

---

## Como validar

Depois do merge na `main`:

```bash
kubectl get applications -n argocd -w
```

O `root` deve sair de `Unknown` para `Synced`, e as cinco `Application` dos serviços aparecem em seguida.

```bash
kubectl get pods -n togglemaster
kubectl get externalsecrets -n togglemaster
```

Os `ExternalSecret` precisam chegar em `SecretSynced` — é o que materializa a senha do RDS a partir do Secrets Manager. O `ClusterSecretStore` `aws-secrets-manager` já está `Valid`/`Ready`, e os cinco segredos existem na conta.

---

## O que fica pendente

**Não há template de Ingress.** O `charts/base/templates/` tem `deployment`, `service`, `configmap`, `externalsecret`, `hpa` e `serviceaccount`. Os serviços sobem como `ClusterIP`, acessíveis apenas de dentro do cluster.

Para validar por fora, `kubectl port-forward` resolve. Para expor de fato pelo ALB provisionado pelo AWS Load Balancer Controller, falta o template.

**`imagePullSecrets: ecr-registry-secret`.** Os `values-prod.yaml` referenciam um secret que não existe no cluster. O pull do ECR normalmente funciona pela role do nó, mas o Kubernetes registrará evento de secret ausente. Vale remover a referência ou criar o secret.

**A validação de ponta a ponta ainda não aconteceu.** O diagnóstico provou que o chart renderiza; não provou que os pods sobem, que os `ExternalSecret` sincronizam nem que os serviços conectam no RDS. Isso só é observável depois do merge.
