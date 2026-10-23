# Auditoria técnica: rclone e SharePoint Fácil 1.1.3

Revisão feita sobre o rclone 1.75.1 integrado ao produto e sobre a documentação
e o código público do projeto rclone. O objetivo é oferecer uma unidade do
SharePoint confiável no Windows sem esconder as limitações do backend.

## Configuração adotada

| Área | Decisão | Motivo |
|---|---|---|
| Backend | `onedrive`, `drive_id` da biblioteca e `drive_type=documentLibrary` | Impede que a unidade caia no OneDrive pessoal da conta. |
| Autorização | OAuth delegado por usuário e token protegido no perfil do Windows | Mantém as permissões reais do Microsoft 365 e evita uma identidade compartilhada. |
| Montagem | WinFsp, `cmount`, `network_mode` e nome de volume único | É a implementação disponível no binário oficial Windows e produz uma unidade de rede no Explorer. |
| Arquivos Office | `vfs_cache_mode=full`, write-back de 2 s e cache exclusivo do controlador | Permite seek, leitura/gravação simultânea, arquivos temporários, substituição e repetição de uploads falhos. |
| Limite do cache | 10 GB, mínimo de 2 GB livres e expiração após 24 h | Evita crescimento indefinido sem remover arquivos abertos ou pendentes. O rclone pode ultrapassar temporariamente o limite. |
| Mudanças externas | `poll_interval=15s`, `dir_cache_time=24h` e observador do Explorer | O OneDrive implementa ChangeNotify pela API delta, então o cache de diretórios pode ser longo sem reler pastas grandes a cada atualização do Explorer. O `cmount` ainda não invalida por completo o cache do kernel/Explorer. |
| Desempenho | `attr_timeout=10s`, `vfs_read_chunk_streams=8` e `vfs_read_chunk_size=8M` | Reduz consultas de atributos repetidas pelo Explorer e baixa arquivos grandes em requisições paralelas. |
| Upload OneDrive | `upload_cutoff=off` | Mantém upload em sessão em todos os tamanhos e evita a versão extra causada pelo upload simples de arquivos pequenos. |
| Integridade | `IgnoreSize` e `IgnoreChecksum` no `_config` do mount | O SharePoint regrava arquivos Office no envio (metadados da biblioteca), e o tamanho e o hash nunca coincidem com o cache. Sem as duas opções, todo salvamento Office falha como `corrupted on transfer`, fica preso no cache e é reenviado indefinidamente (confirmado em biblioteca real em 23/10/2026; ver "Unexpected file size/hash differences on Sharepoint" na documentação do rclone). |
| Exclusão | `hard_delete=false` | Arquivos removidos continuam passando pela lixeira do SharePoint. |
| Versões | `no_versions=false` | O histórico de versões da biblioteca é preservado. |
| Antivírus Microsoft | `av_override=false` | O aplicativo não força o download de conteúdo marcado como malware. |
| Symlinks | tradução **desligada** (sem `Links`) | Com a tradução ligada, qualquer pessoa com escrita na biblioteca podia enviar um `.rclonelink` que aparecia na unidade como link simbólico para um caminho local ou UNC qualquer. O `cmount` em modo de rede funciona sem ela (verificado em 23/10/2026: montagem, salvamento no estilo Office e envio real). Efeito colateral: o rclone registra uma vez, ao montar, `symlinks not supported without the --links flag: /`, sem impacto. |
| Controlador local | credencial RC só enviada ao rclone do próprio app | Antes de qualquer requisição, o app confere PID, executável, horário de início e o dono da porta de escuta em `127.0.0.1` (`Test-ControllerIdentity`). Impede que outro usuário do mesmo computador receba a credencial ou o token OAuth ocupando a porta. |

## Atualização automática

O backend OneDrive do rclone usa a API delta para ChangeNotify. O intervalo de
15 segundos invalida o cache de diretórios do VFS quando outro usuário, Teams ou
o site do SharePoint altera um item. O rclone oficial 1.75.1 ainda tem uma lacuna:
essa invalidação não chega sempre ao cache de diretórios mantido pelo Windows em
montagens `cmount`.

O SharePoint Fácil executa um observador gráfico sem console e único por usuário.
A cada ciclo ele confirma as montagens no controlador local e envia
`SHCNE_UPDATEDIR` apenas para a raiz e para as pastas abertas das unidades do
produto. Assim, o Explorer volta a enumerar a pasta sem F5 e sem uma listagem
recursiva da biblioteca. O observador encerra após duas verificações sem nenhuma
unidade montada.

O tempo normal de convergência é de até aproximadamente 30 segundos: até 15 s
para o ChangeNotify do rclone e até 15 s para o aviso ao Explorer. O comando
`Atualizar` continua disponível; antes de usar `vfs/forget`, ele confirma que não
há gravações locais pendentes.

## O que já se aproxima dos produtos pagos

- seleção de sites e bibliotecas acessíveis pela conta;
- letra, nome e reconexão no logon por biblioteca;
- autenticação delegada e renovação do token;
- acesso sob demanda sem sincronizar toda a biblioteca;
- cache VFS compatível com operações comuns do Office;
- proteção contra desmontagem e remoção com upload pendente;
- duplo clique que abre documentos Office pelo SharePoint (coautoria), com
  checkout/check-in pelo próprio Office;
- sincronização opcional de qualquer biblioteca pelo cliente OneDrive;
- atualização automática de mudanças externas;
- instalador com rclone e WinFsp integrados e execução sem VBS/console;
- configuração criptografada, ACL privada e logs com remoção de segredos.

## Lacunas para competir em ambiente corporativo

1. **Arquivos que não são Office.** O duplo clique em DOCX/XLSX/PPTX já abre
   pelo SharePoint (e o Office cuida de checkout e coautoria); outros tipos
   continuam sendo gravações VFS comuns, sem bloqueio no servidor.
2. **Estado visual por arquivo.** Não há overlay no Explorer para indicar
   download, upload pendente, erro, cache local ou proprietário do bloqueio. O
   rclone ainda não expõe um estado VFS completo por arquivo pela API RC.
3. **Conflitos e recuperação.** É necessário um painel próprio de uploads com
   erro, tentativas, cópia de recuperação e instrução clara quando o arquivo
   remoto mudou durante uma edição local.
4. **Administração central.** Ainda faltam políticas por grupos do Entra ID,
   publicação de unidades, telemetria com consentimento, atualização automática,
   canais de versão e implantação documentada por Intune/GPO.
5. **Funções do SharePoint no Explorer.** Pesquisa indexada, histórico de versões,
   compartilhamento de links, metadados, retenção e abertura no navegador ainda
   podem ser ampliados no menu de contexto.
6. **Qualificação em escala.** Antes de venda ampla, executar matriz de testes
   com Windows 10/11, Office 32/64 bits, bibliotecas grandes, MFA/Conditional
   Access, convidados, nomes longos, throttling, suspensão do notebook, perda de
   rede e múltiplas contas.
7. **Identidade e assinatura do produto.** A distribuição comercial deve usar
   um aplicativo próprio da UTI DA INFORMATICA LTDA no Microsoft Entra, com
   redirect de cliente público, consentimento e documentação de permissões. O
   launcher, o MSI e o bootstrapper também precisam de Authenticode emitido para
   a empresa; preencher apenas o campo fabricante não cria confiança criptográfica.

Essas lacunas exigem recursos próprios acima do rclone. Alterar flags do mount
não cria bloqueio distribuído, overlays, administração ou recuperação. A base
atual é adequada para um produto piloto; a próxima prioridade técnica deve ser
o painel de integridade e recuperação de uploads, seguido da integração do ciclo
de abertura/fechamento de arquivos Office.

## Fontes primárias consultadas

- https://rclone.org/commands/rclone_mount/
- https://rclone.org/onedrive/
- https://github.com/rclone/rclone/blob/master/backend/onedrive/onedrive.go
- https://github.com/rclone/rclone/pull/9628
- https://github.com/rclone/rclone/issues/9738
- https://docs.zeedrive.com/feature-guide
- https://docs.zeedrive.com/microsoft-office
- https://docs.mountainduck.io/mountainduck/locking/
- https://www.netdrive.net/blog/fix-office-files-opening-read-only-netdrive/
