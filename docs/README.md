# Documentação — togglemaster-gitops

Registro dos desafios técnicos e correções aplicadas durante o desenvolvimento do ToggleMaster (FIAP). A numeração acompanha a fase do Tech Challenge.

Cada documento descreve: o problema, a causa, o erro observado, como foi descoberto, a correção e como validar.

## Guias e decisões: no repositório `.github`

Os desafios abaixo são registro histórico deste repositório e continuam aqui. O que **atravessa repositórios** foi centralizado em [`fiap-tech-challenge-devops/.github`](https://github.com/fiap-tech-challenge-devops/.github/tree/main/docs):

| Lá | O quê |
|---|---|
| [Kubernetes e GitOps](https://github.com/fiap-tech-challenge-devops/.github/blob/main/docs/kubernetes/README.md) | O que este repositório cobre, e para onde olhar |
| [Guia de observabilidade](https://github.com/fiap-tech-challenge-devops/.github/blob/main/docs/observabilidade/guia.md) | Como o dado flui e como ligar cada backend — **estava neste repositório, em `guia-observabilidade.md`** |
| [Registro de decisões](https://github.com/fiap-tech-challenge-devops/.github/tree/main/docs/decisoes) | Por que o chart de terceiros entra como wrapper, por que uma Application por componente, e as demais |

O guia descreve cinco repositórios de serviço mais este e o Collector. Não havia repositório onde ele ficasse ao lado de tudo que descreve — por isso saiu daqui.

**A regra:** documento sobre algo que vive só neste repositório fica em `desafios/`, atualizado no mesmo PR que muda o código. Se vincula vários, vai para o `.github`.

## Desafios

| # | Documento | Escopo |
|---|-----------|--------|
| 03 | [App-of-apps do Argo CD](desafios/03-argocd-app-of-apps.md) | Layout de `applications/`, restrição do kustomize e validação do `valueFiles` |
| 04 | [Ingress e lacunas do chart](desafios/04-ingress-e-lacunas-do-chart.md) | Template de Ingress com `group.name`, correção do `envFrom` e o que falta adaptar |
| 05 | [IRSA, migrations e KEDA](desafios/05-irsa-migrations-e-keda.md) | Anotação de role no ServiceAccount, Job de migration por sync-wave e escala por fila |
| 06 | [O primeiro sync real](desafios/06-primeiro-sync-real.md) | Impasse de `sync-wave` no KEDA e o `REDIS_URL` que nunca foi substituído |
| 07 | [Bootstrap da chave de serviço](desafios/07-bootstrap-da-chave-de-servico.md) | `SERVICE_API_KEY` semeada na migration, `checksum/config` e `replicas` sob autoscaler |
| 08 | [Collector e charts de terceiros](desafios/08-otel-collector-e-charts-de-terceiros.md) | Chart wrapper, um componente por Application e o bloco `otel` no chart base |
