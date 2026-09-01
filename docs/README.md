# Documentação — togglemaster-gitops

Registro dos desafios técnicos e correções aplicadas durante o desenvolvimento do ToggleMaster (FIAP). A numeração acompanha a fase do Tech Challenge.

Cada documento descreve: o problema, a causa, o erro observado, como foi descoberto, a correção e como validar.

## Desafios

| # | Documento | Escopo |
|---|-----------|--------|
| 03 | [App-of-apps do Argo CD](desafios/03-argocd-app-of-apps.md) | Layout de `applications/`, restrição do kustomize e validação do `valueFiles` |
| 04 | [Ingress e lacunas do chart](desafios/04-ingress-e-lacunas-do-chart.md) | Template de Ingress com `group.name`, correção do `envFrom` e o que falta adaptar |
| 05 | [IRSA, migrations e KEDA](desafios/05-irsa-migrations-e-keda.md) | Anotação de role no ServiceAccount, Job de migration por sync-wave e escala por fila |
| 06 | [O primeiro sync real](desafios/06-primeiro-sync-real.md) | Impasse de `sync-wave` no KEDA e o `REDIS_URL` que nunca foi substituído |
