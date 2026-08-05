# togglemaster-gitops

Fonte de verdade do que roda no cluster do **ToggleMaster**. Contém apenas manifests Kubernetes e Helm charts — nenhum código de aplicação, nenhum Terraform.

O Argo CD observa este repositório e sincroniza o cluster com o que está aqui. Nada é aplicado com `kubectl apply` manual: se não está neste repositório, não deveria estar rodando.

Faz parte de um conjunto de quatro repositórios:

| Repositório | Papel |
|---|---|
| [`terraform-aws-modules`](https://github.com/fiap-tech-challenge-devops/terraform-aws-modules) | Biblioteca de módulos Terraform reutilizáveis |
| [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac) | Provisiona a infraestrutura AWS |
| **`togglemaster-gitops`** | **Manifests consumidos pelo Argo CD (este repo)** |
| [`reusable-workflows`](https://github.com/fiap-tech-challenge-devops/reusable-workflows) | Workflows de CI/CD chamados pelos microsserviços |

## Estrutura prevista

```
charts/
└── microservice/          # chart único, parametrizado, servindo os 5 serviços
    ├── Chart.yaml
    ├── values.yaml        # valores padrão
    └── templates/         # deployment, service, configmap, hpa, serviceaccount…
apps/
├── auth-service/values.yaml
├── flag-service/values.yaml
├── targeting-service/values.yaml
├── evaluation-service/values.yaml
└── analytics-service/values.yaml
platform/                  # recursos compartilhados: namespace, ingress, ClusterSecretStore
argocd/                    # Applications e o app-of-apps
```

### Um chart, cinco values

Os cinco microsserviços têm o mesmo formato de deployment — mudam imagem, porta, variáveis de ambiente e política de escala. Um chart parametrizado com um `values.yaml` por serviço evita cinco cópias do mesmo `deployment.yaml` que divergem com o tempo.

### `apps/` é o que a esteira altera

A pipeline de CD de cada microsserviço atualiza **apenas** a tag da imagem no `values.yaml` do serviço correspondente:

```yaml
image:
  repository: 123456789012.dkr.ecr.us-east-1.amazonaws.com/togglemaster/auth-service
  tag: v1.0.0-a1b2c3d
```

O commit é o registro auditável do que foi promovido, quando e por qual build. O Argo CD detecta a mudança e sincroniza.

## Fluxo de deploy

```
merge na main do microsserviço
  → CI builda, escaneia e publica a imagem no ECR
  → CD commita a nova tag em apps/<serviço>/values.yaml (aqui)
  → Argo CD detecta a diferença
  → sync automático
  → nova versão no cluster
```

Nenhuma etapa desse fluxo envolve alguém rodando `kubectl` na própria máquina.

## Argo CD

Instalado no cluster pelo stage `platform` do [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac) — alguém precisa instalar o Argo CD antes de ele poder instalar as outras coisas. A partir daí, tudo passa por aqui.

O diretório `argocd/` segue o padrão **app-of-apps**: uma Application raiz que aponta para as demais, de modo que adicionar um componente à plataforma é um commit neste repositório, não uma mudança no Terraform.

Componentes de plataforma gerenciados por aqui: External Secrets Operator, AWS Load Balancer Controller, Karpenter (o chart — o IAM vem do Terraform), KEDA, cert-manager e a stack de observabilidade.

## Valores que vêm do Terraform

Alguns campos de manifest dependem de recursos criados pelo `togglemaster-iac` — ARNs de roles IRSA, nome da fila de interrupção do Karpenter, nome da role dos nós no `EC2NodeClass`.

Esses valores são **nomes determinísticos**, derivados do nome do cluster, e ficam escritos nos `values.yaml` como string estável. Os módulos também os publicam no SSM Parameter Store, para consulta e depuração.

A alternativa seria resolvê-los em tempo de render, com um plugin como o `argocd-vault-plugin`. Não é o caminho adotado: adiciona uma peça móvel no repo-server para resolver algo que já é previsível.

## Convenções

- Um diretório por serviço em `apps/`, com o mesmo nome do repositório do microsserviço
- Nenhum segredo em texto plano: credenciais vêm do Secrets Manager via External Secrets Operator
- Mudanças de plataforma passam por Pull Request; a esteira de CD só altera a tag da imagem
