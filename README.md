# Windfull

Projeto pessoal para controlar um ar-condicionado Samsung WindFree pelo Android, com um host Windows e comunicação na rede local. O host tem uma interface de desktop com bandeja do sistema, controles, configuração e aprovação de celulares; o servidor roda junto com esse aplicativo, sem painel web.

## Recursos implementados

- O Android procura automaticamente hosts Windfull na LAN por UDP; também permite informar um IPv4 e faz a mesma descoberta por unicast.
- O pareamento exige aprovação no PC e comparação de um código de seis dígitos. A identidade do host é fixada pelo fingerprint SHA-256 do certificado TLS. O segredo de pareamento fica no armazenamento seguro do Android, e a reconexão atualiza IP/porta somente quando ID e fingerprint coincidem.
- O host oferece gerenciamento de dispositivos pareados e serviço HTTPS local. Os controles no celular são exibidos conforme as capacidades anunciadas pelo host/aparelho.
- A bridge Samsung usa OCF/CoAP sobre DTLS e só expõe recursos anunciados pelo dispositivo.

O fluxo DTLS, a leitura de estado e comandos idempotentes de energia, temperatura, ventilação, modo e WindFree foram confirmados fisicamente no aparelho de teste. O pareamento e controle ponta a ponta pelo Android ainda não foram validados. Isso não implica compatibilidade com todos os modelos ou firmwares Samsung. Consulte [`server/native/samsung/README.md`](server/native/samsung/README.md) para as limitações conhecidas.

## Estrutura

| Diretório | Finalidade |
| --- | --- |
| `app/` | Cliente Android em Flutter: descoberta, pareamento, estado e controles dinâmicos. |
| `server/` | Aplicativo Windows, serviço HTTPS, descoberta, aprovação e integração Samsung. |
| `server/native/samsung/` | Bridge OCF escrita em Rust. |
| `app/assets/brand/` | Marca vetorial editável compartilhada pelos ícones do cliente e host. |
| `scripts/` | Builds e verificação dos artefatos. |
| `docs/releasing.md` | Procedimento para builds de distribuição e releases. |

## Desenvolvimento

Use Flutter 3.44.1 ou compatível com os constraints do projeto. Para Windows, instale Visual Studio Build Tools com o workload **Desktop development with C++** e Windows SDK. A bridge requer Rust stable para MSVC e Strawberry Perl. O build oficial detecta Perl instalado ou a cópia portátil em `%LOCALAPPDATA%\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin`; não altera o PATH global. Use `-PerlBin` para indicar outra pasta ou o caminho de `perl.exe`.

Analisar e testar os projetos:

```powershell
cd app
flutter pub get
flutter analyze
flutter test
cd ../server
flutter pub get
flutter analyze
flutter test
cd ..
```

Para executar o host Windows durante o desenvolvimento, construa primeiro a bridge Debug e inicie o Flutter:

```powershell
cargo build --locked --manifest-path server/native/samsung/Cargo.toml
cd server
flutter run -d windows
```

O CMake instala a bridge ao lado do host em Debug ou Release quando o binário correspondente já existe. O build oficial sempre compila a bridge Release e interrompe a distribuição se ela não for gerada.

Para testar o Android, abra `app/` e rode `flutter run` em um dispositivo/emulador. Sem um host Windfull, o app mostra o estado desconectado e não ativa controles. A descoberta broadcast é principal; em rede que bloqueia broadcast, use **Inserir IP do computador**. Esse fluxo mantém o anúncio, o pinning TLS e a confirmação do código de pareamento.

## Build local

No Windows, gere o host e a bridge portátil e o APK Android de teste:

```powershell
.\scripts\build_windows.ps1
.\scripts\build_android.ps1 -AllowDebugSigning
.\scripts\verify_release.ps1 -AllowDebugSigning
```

Se Perl não estiver em um dos locais detectados:

```powershell
.\scripts\build_windows.ps1 -PerlBin "$env:LOCALAPPDATA\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin"
```

O ZIP Windows contém `windfull_server.exe`, `windfull-samsung-ocf.exe` e os arquivos do bundle Flutter. Artefatos são gravados em `output/`, que não deve ser commitado. APK assinado com a chave de depuração serve somente para teste. Para distribuir Android, configure uma keystore própria e mantenha a mesma chave nas atualizações; consulte [`docs/releasing.md`](docs/releasing.md).

## Referências

- [Samsung WindFree Tray App](https://github.com/c0dag/samsung-windfree-tray-app): referência de UX; o projeto não incorpora código desse repositório.
- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli): ferramenta oficial para APIs SmartThings.
