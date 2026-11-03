# Windfull

Controle seu ar-condicionado Samsung WindFree pelo Android, com um host Windows na sua rede local.

O Windfull conecta o celular ao aparelho por meio do computador e oferece controles compatíveis com os recursos do ar-condicionado.

## Controles

- Ligar e desligar
- Ajustar a temperatura
- Selecionar modo de operação e velocidade de ventilação
- Ativar ou desativar o WindFree

Os controles disponíveis acompanham os recursos anunciados pelo aparelho.

## Conectar

1. Inicie o Windfull no computador Windows.
2. Abra o app Android com o celular e o computador na mesma rede local.
3. Selecione o computador, confira o código de pareamento e aprove o celular no host.

O pareamento fica salvo para as próximas conexões.

## Compilar

Requisitos: Flutter, Rust stable e Visual Studio com o workload **Desktop development with C++**. No Windows, execute na pasta do projeto:

```powershell
.\scripts\build_windows.ps1
.\scripts\build_android.ps1
```

Os artefatos são gravados em `output/`. Consulte [`docs/releasing.md`](docs/releasing.md) para o processo de distribuição.

## Estrutura

| Pasta | Conteúdo |
| --- | --- |
| `app/` | Aplicativo Android em Flutter |
| `server/` | Host Windows e integração com o aparelho |
| `scripts/` | Scripts de build e verificação |

## Licença

Distribuído sob os termos da [GNU General Public License v3.0 ou posterior](LICENSE).
