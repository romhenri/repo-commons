# repo-commons

Painel nativo para macOS que mostra vários repositórios git de uma vez. Implementação clean-room, open source (GPL-3.0), inspirada em ferramentas de "frota de repos" como o RepoFlock. Não contém código nem assets de terceiros.

## O que faz

1. Você escolhe pastas; cada repo no **primeiro nível** delas entra no dashboard.
2. **Fetch / Pull em lote** por pasta ou em todas, com até 4 operações em paralelo. O pull é sempre `--ff-only` e só roda quando você clica: um branch divergente falha com a mensagem do git e o repo fica intocado.
3. **Mudanças não commitadas**: staged, modified e untracked, respeitando o `.gitignore`.
4. **Commits não enviados**: ahead/behind da branch atual, branch sem upstream e outras branches locais com commits pendentes.

O status atualiza ao abrir o app, no botão Atualizar (⌘R) e depois de cada fetch/pull.

## Requisitos

macOS 14+ e `git` em `/usr/bin/git` (Command Line Tools). Não precisa de Xcode.

## Rodar e buildar

```sh
swift run RepoCommons   # rodar em dev
swift test              # testes de integração (repos git reais em diretório temporário)
./bundle.sh             # gera dist/RepoCommons.app e dist/RepoCommons.zip (universal, sem assinatura)
```

O app não é notarizado. Na primeira abertura, use clique direito > Abrir.

## Licença

GPL-3.0. Veja [LICENSE](LICENSE).
