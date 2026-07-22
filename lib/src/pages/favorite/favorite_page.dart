import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';

import '../base/base_page.dart';
import 'favorite_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePage extends BasePage {
  const FavoritePage({
    Key? key,
    bool showMenuButton = false,
    bool showTitle = false,
    String? name,
  }) : super(
          key: key,
          showMenuButton: showMenuButton,
          showJumpButton: true,
          showFilterButton: true,
          showScroll2TopButton: true,
          showTitle: showTitle,
          name: name,
        );

  @override
  FavoritePageLogic get logic =>
      Get.put<FavoritePageLogic>(FavoritePageLogic(), permanent: true);

  @override
  FavoritePageState get state => Get.find<FavoritePageLogic>().state;

  @override
  List<Widget> buildAppBarActions() {
    return [
      if (state.gallerys.isNotEmpty)
        IconButton(
            icon: const Icon(FontAwesomeIcons.paperPlane, size: 20),
            onPressed: logic.handleTapJumpButton),
      if (state.gallerys.isNotEmpty)
        IconButton(
            icon: const Icon(Icons.sort),
            onPressed: logic.handleChangeSortOrder),
      IconButton(
          icon: const Icon(Icons.filter_alt_outlined, size: 28),
          onPressed: logic.handleTapFilterButton),
      IconButton(
          icon: const Icon(Icons.download),
          onPressed: logic.handleTapDownloadAll),
    ];
  }

  @override
  Widget buildBody(BuildContext context) {
    return Stack(
      children: [
        buildListBody(context),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _BatchDownloadProgressBanner(),
        ),
      ],
    );
  }
}

class _BatchDownloadProgressBanner extends StatelessWidget {
  const _BatchDownloadProgressBanner();

  @override
  Widget build(BuildContext context) {
    return GetBuilder<FavoritePageLogic>(
      id: Get.find<FavoritePageLogic>().batchDownloadProgressId,
      builder: (_) {
        FavoritePageLogic logic = Get.find<FavoritePageLogic>();
        FavoritePageState state = logic.state;

        // State 1: batch download in progress → show progress bar.
        if (state.isBatchDownloading) {
          String progressText;
          if (state.batchDownloadPhase == 'loadingFavorites') {
            progressText =
                '${'loadingAllFavorites'.tr} ${state.batchDownloadTotalCount}';
          } else {
            progressText = '${'batchDownloading'.tr} '
                '${state.batchDownloadCurrentCount}/${state.batchDownloadTotalCount}';
          }

          return Material(
            elevation: 4,
            color: Theme.of(context).colorScheme.primaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        progressText,
                        style: TextStyle(
                          fontSize: 13,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // State 2: loading failed → show 30-min countdown + "Interrupt Wait".
        if (state.batchDownloadFailureTime != null &&
            logic.failureCountdownRemainingSeconds > 0) {
          String countdownText = 'batchDownloadFailureCountdown'
              .tr
              .replaceAll('\$time', logic.failureCountdownFormatted);

          return Material(
            elevation: 4,
            color: Theme.of(context).colorScheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        countdownText,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: logic.handleInterruptWait,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'interruptWait'.tr,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // State 3: idle → hide.
        return const SizedBox.shrink();
      },
    );
  }
}
