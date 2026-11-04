import 'package:flutter/material.dart';

import '../ui/windfull_palette.dart';
import 'android_update_controller.dart';

class AndroidUpdatesSheet extends StatelessWidget {
  const AndroidUpdatesSheet({required this.controller, super.key});

  final AndroidUpdateController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final update = controller.candidate;
      final checking = controller.status == AndroidUpdateStatus.checking;
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Atualizações',
                        style: TextStyle(
                          color: WindfullPalette.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Verificar agora',
                      onPressed:
                          checking ||
                              controller.status ==
                                  AndroidUpdateStatus.downloading ||
                              controller.status ==
                                  AndroidUpdateStatus.downloaded ||
                              controller.status ==
                                  AndroidUpdateStatus.permissionRequired
                          ? null
                          : controller.check,
                      icon: checking
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                Text(
                  'Versão instalada: ${controller.currentVersion ?? '—'}',
                  style: const TextStyle(
                    color: WindfullPalette.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 18),
                _StatusCard(controller: controller),
                if (update != null) ...[
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: WindfullPalette.surface,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Versão ${update.version}',
                            style: const TextStyle(
                              color: WindfullPalette.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 9),
                          const Text(
                            'Notas da versão',
                            style: TextStyle(
                              color: WindfullPalette.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Text(
                                update.notes.isEmpty
                                    ? 'Sem notas para esta versão.'
                                    : update.notes,
                                style: const TextStyle(
                                  color: WindfullPalette.muted,
                                  height: 1.5,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          _UpdateAction(controller: controller),
                        ],
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final AndroidUpdateController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final (icon, title, subtitle) = switch (status) {
      AndroidUpdateStatus.idle => (
        Icons.system_update_alt_rounded,
        'Atualizações automáticas',
        'O WindFull verifica novas versões publicadas no GitHub.',
      ),
      AndroidUpdateStatus.checking => (
        Icons.sync_rounded,
        'Verificando versões',
        'Consultando a release oficial do WindFull.',
      ),
      AndroidUpdateStatus.upToDate => (
        Icons.check_circle_outline_rounded,
        'Você está atualizado',
        'Nenhuma versão mais recente está disponível.',
      ),
      AndroidUpdateStatus.available => (
        Icons.system_update_alt_rounded,
        'Nova versão disponível',
        'O download só começa quando você aprovar.',
      ),
      AndroidUpdateStatus.downloading => (
        Icons.downloading_rounded,
        'Baixando atualização',
        'O Android continuará o download em segundo plano.',
      ),
      AndroidUpdateStatus.downloaded => (
        Icons.verified_rounded,
        'Download verificado',
        'A instalação só começa depois da sua confirmação.',
      ),
      AndroidUpdateStatus.manualInstallRequired => (
        Icons.install_mobile_rounded,
        'Instalação inicial necessária',
        'A chave desta cópia difere da oficial. Remova esta instalação e instale o APK da release; depois, solicite novo pareamento no PC. As próximas atualizações serão instaladas normalmente.',
      ),
      AndroidUpdateStatus.permissionRequired => (
        Icons.security_rounded,
        'Permissão de instalação necessária',
        'Permita instalações pelo WindFull nas configurações do Android e depois toque em Instalar novamente.',
      ),
      AndroidUpdateStatus.installing => (
        Icons.open_in_new_rounded,
        'Instalador do Android aberto',
        'Confirme a atualização na janela do Android. Se cancelar, verifique novamente para tentar outra vez.',
      ),
      AndroidUpdateStatus.failed => (
        Icons.error_outline_rounded,
        'Não foi possível atualizar',
        controller.errorMessage ?? 'Verifique sua conexão e tente novamente.',
      ),
    };
    final accent = status == AndroidUpdateStatus.failed
        ? const Color(0xFFF0BC70)
        : WindfullPalette.accent;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WindfullPalette.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 21),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: WindfullPalette.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: WindfullPalette.muted,
                    height: 1.4,
                    fontSize: 11,
                  ),
                ),
                if (status == AndroidUpdateStatus.downloading) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: controller.progressPercent / 100,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${controller.progressPercent}%',
                    style: const TextStyle(
                      color: WindfullPalette.muted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateAction extends StatelessWidget {
  const _UpdateAction({required this.controller});

  final AndroidUpdateController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    if (status == AndroidUpdateStatus.available) {
      return FilledButton.icon(
        onPressed: controller.approveDownload,
        icon: const Icon(Icons.download_rounded),
        label: const Text('Baixar atualização'),
      );
    }
    if (status == AndroidUpdateStatus.downloading) {
      return OutlinedButton.icon(
        onPressed: controller.cancelDownload,
        icon: const Icon(Icons.close_rounded),
        label: const Text('Cancelar download'),
      );
    }
    if (status == AndroidUpdateStatus.downloaded ||
        status == AndroidUpdateStatus.permissionRequired) {
      return FilledButton.icon(
        onPressed: controller.install,
        icon: const Icon(Icons.install_mobile_rounded),
        label: const Text('Instalar atualização'),
      );
    }
    if (status == AndroidUpdateStatus.manualInstallRequired) {
      return FilledButton.tonalIcon(
        onPressed: controller.openReleasePage,
        icon: const Icon(Icons.open_in_new_rounded),
        label: const Text('Abrir release oficial'),
      );
    }
    return const SizedBox.shrink();
  }
}
