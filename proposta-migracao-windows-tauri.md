# Proposta: migrar o host Windows para Tauri

## Objetivo

Trocar a janela Flutter do host Windows por um aplicativo Tauri com interface web, mantendo o painel compacto, sem moldura e ancorado à bandeja do sistema. O cliente Android continua em Flutter. O produto permanece um app de bandeja, não um dashboard no navegador.

## Stack proposta

- **Tauri 2 + Rust** para bandeja, janela, ciclo de vida e serviços locais.
- **Vite + React + TypeScript** para organizar controles, configurações, pareamento e energia em componentes.
- **Tailwind CSS** para layout e estilos utilitários; CSS próprio para identidade visual, ilustração e animações. Sem biblioteca pesada de componentes ou animação.
- Reutilizar a integração OCF em Rust existente. O WebView do Windows renderiza a interface; não empacotar um navegador separado.

## Arquitetura e migração

1. Recriar o painel de controle e as telas de ajustes como interface do Tauri, com estados, animações e arte próprios para o WindFull.
2. Migrar os serviços do host Dart para Rust, mantendo a API HTTPS local e seu contrato com o Android.
3. Ligar a interface ao host por comandos Tauri. A API LAN continua dedicada ao cliente Android.
4. Remover o host Flutter Windows após validar bandeja, descoberta, aprovação, controles, atualizações e inicialização com o Windows.

Preservar a identidade do servidor, certificados, pareamentos e configurações durante a migração e em atualizações. O Android não precisa mudar de stack nem de fluxo.

## Critérios

- Painel rápido, fluido e posicionado junto ao ícone da bandeja.
- Instalação e uso de memória medidos no Windows; não assumir ganhos sem comparar builds.
- Sem dependências visuais grandes quando CSS e componentes próprios forem suficientes.
- Reutilizar o código Rust do aparelho e manter todo o controle na rede local.

## Decisão

Tauri é uma alternativa viável e alinhada à referência. A mudança exige portar os serviços Dart do host, não apenas refazer a tela. A qualidade visual virá do desenho, da tipografia, das ilustrações e das animações; a stack web facilita esse trabalho, mas não o garante.
