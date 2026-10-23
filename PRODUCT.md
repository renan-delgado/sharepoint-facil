# SharePoint Fácil

## Problema e objetivo

Clientes que migraram do servidor de arquivos para o SharePoint Online querem
continuar trabalhando por uma letra de unidade no Explorador. A sincronização
do OneDrive lista a biblioteca inteira antes de funcionar e fica lenta ou
trava em bibliotecas grandes, motivo das reclamações dos clientes. O
SharePoint Fácil monta cada biblioteca como unidade com acesso
sob demanda: pastas são listadas ao abrir e arquivos baixados ao usar.

## Público

- Usuários finais de empresas atendidas pela UTI DA INFORMATICA, em Windows
  10/11 de 64 bits, com contas Microsoft 365.
- O técnico que instala e configura as unidades.
- A comunidade, que usa o projeto aberto (licença MIT).

## Fluxos principais

1. **Conectar biblioteca:** entrar com a conta Microsoft, escolher site e
   biblioteca, letra, nome e reconexão no logon. Resultado: unidade no
   Explorador.
2. **Sincronizar pelo OneDrive (opcional):** na mesma lista de sites e
   bibliotecas, "Sincronizar com o OneDrive" entrega a biblioteca ao
   aplicativo OneDrive, como o botão Sincronizar do SharePoint. Resultado:
   pasta "Site - Biblioteca" no nó da empresa no Explorador. A escolha entre
   unidade e OneDrive fica com o usuário.
3. **Usar a unidade:** navegar, abrir, salvar, copiar e excluir pelo
   Explorador. As alterações sobem em segundo plano e as de outros usuários
   aparecem em até cerca de 30 s.
4. **Abrir documento Office:** o duplo clique em DOCX/XLSX/PPTX abre pelo
   SharePoint (coautoria); se não for possível, abre a cópia da unidade.
5. **Edição exclusiva:** reservar (checkout), editar no Office e concluir
   (check-in) pelo menu de contexto ou pela janela.
6. **Instalar e atualizar:** um instalador que inclui o WinFsp e atualiza a
   versão anterior sem perder as unidades.

## Fora do escopo atual

Ícones de estado por arquivo no Explorador, arquivos fixados para uso
offline, checkout automático ao abrir, painel central de administração,
políticas por grupo do Entra ID e telemetria. Lacunas detalhadas em
[AUDITORIA-RCLONE-SHAREPOINT.md](AUDITORIA-RCLONE-SHAREPOINT.md).

## Requisitos e restrições

- Interface e mensagens em português do Brasil.
- Autenticação delegada por usuário: cada pessoa usa as próprias permissões;
  nenhuma identidade compartilhada.
- Tokens e configuração do rclone ficam criptografados no perfil do usuário,
  com ACL privada; logs não podem conter segredos.
- Exclusões vão para a lixeira do SharePoint e o histórico de versões é
  preservado.
- Sem servidor próprio: o app fala só com a Microsoft e com o rclone local.
- Stack fixada: Windows PowerShell 5.1 + WinForms, rclone, WinFsp e WiX.
  Não há banco de dados nem interface web.

## Suposições e decisões pendentes

- A distribuição comercial ainda usa o aplicativo OAuth padrão do rclone.
  Um aplicativo próprio no Microsoft Entra está pendente.
- O instalador não tem assinatura Authenticode (o SmartScreen avisa).
- O WinFsp fixado é a versão de pré-lançamento 2.2 Beta4, escolhida por
  correções de segurança e de travamentos.

## Critérios de aceite

- Uma biblioteca com milhares de itens monta e a primeira pasta abre sem
  listar a biblioteca inteira.
- Um arquivo Office salvo na unidade aparece no SharePoint, sem ficar
  preso no cache.
- O duplo clique num documento da unidade abre no Office com o local no
  SharePoint; um arquivo fora das unidades abre como antes.
- A atualização para uma versão nova mantém as unidades configuradas.
- A desinstalação devolve ao Office o comportamento "Abrir" original.

## Próxima entrega

Painel de envios com erro, tentativas e recuperação, a primeira prioridade
técnica apontada na auditoria. Depende de expor o estado por arquivo do
cache VFS do rclone.

## Manutenção

Atualize este documento quando mudarem o objetivo, o escopo, as restrições
ou os critérios de aceite. Decisões técnicas ficam em
[docs/architecture.md](docs/architecture.md); evidências, em
[docs/setup.md](docs/setup.md).
